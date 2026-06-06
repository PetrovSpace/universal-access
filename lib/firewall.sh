#!/usr/bin/env bash
# lib/firewall.sh — фаервол: открываем только нужные порты, не теряя SSH-сессию.
# Источаемый модуль: вызывается после common.sh. Предпочтение nftables, фолбэк ufw.
set -euo pipefail

# --- Определение порта работающего sshd --------------------------------------
firewall_detect_ssh_port() {
  # Печатает текущий SSH-порт. По умолчанию 22. Сначала смотрим на реально
  # слушающие сокеты sshd, затем на sshd_config, иначе fallback 22.
  local port=''

  # 1) Активные слушающие сокеты sshd (самый надёжный источник).
  if command -v ss >/dev/null 2>&1; then
    port=$(ss -tlnpH 2>/dev/null \
      | awk '/sshd/ {print $4}' \
      | sed -E 's/.*[:.]([0-9]+)$/\1/' \
      | grep -E '^[0-9]+$' \
      | head -n1) || port=''
  fi

  # 2) Порт нашей собственной SSH-сессии (SSH_CONNECTION: "cl_ip cl_port srv_ip srv_port").
  if [[ -z "$port" && -n "${SSH_CONNECTION:-}" ]]; then
    port=$(printf '%s\n' "$SSH_CONNECTION" | awk '{print $4}' | grep -E '^[0-9]+$' || true)
  fi

  # 3) Директива Port из эффективного конфига sshd (берём первую).
  if [[ -z "$port" ]] && command -v sshd >/dev/null 2>&1; then
    port=$(sshd -T 2>/dev/null | awk '/^port / {print $2; exit}' | grep -E '^[0-9]+$' || true)
  fi
  if [[ -z "$port" && -r /etc/ssh/sshd_config ]]; then
    port=$(awk '/^[[:space:]]*[Pp]ort[[:space:]]+[0-9]+/ {print $2; exit}' /etc/ssh/sshd_config \
      | grep -E '^[0-9]+$' || true)
  fi

  printf '%s\n' "${port:-22}"
}

# --- Сбор списка открываемых портов ------------------------------------------
_firewall_collect_ports() {
  # Заполняет переданные по nameref массивы TCP- и UDP-портами.
  # Использование: _firewall_collect_ports tcp_arr udp_arr
  local -n _tcp_ref="$1"
  local -n _udp_ref="$2"
  local ssh_port; ssh_port=$(firewall_detect_ssh_port)

  # Порты MTProto/AmneziaWG могли быть авто-сдвинуты при install и сохранены в
  # state. Предпочитаем сохранённые значения — иначе при standalone-вызове
  # (отдельный прогон фаервола) открылись бы дефолтные порты, а не реальные.
  local mt_port awg_port
  mt_port="$(state_get mtproto_port)"; [[ -n "$mt_port" ]] || mt_port="${MTPROTO_PORT:-8888}"
  awg_port="$(state_get awg_port)";    [[ -n "$awg_port" ]] || awg_port="${AWG_PORT:-51820}"

  _tcp_ref=(
    "$ssh_port"
    "${REALITY_PORT_BLACKLIST:-443}"
    "${REALITY_PORT_WHITELIST:-8443}"
    "$mt_port"
  )
  _udp_ref=("$awg_port")

  # Hysteria2 (UDP) — только если включён.
  if [[ "${ENABLE_HYSTERIA2:-false}" == "true" ]]; then
    _udp_ref+=("${HYSTERIA2_PORT:-36712}")
  fi
}

# --- nftables ----------------------------------------------------------------
_firewall_setup_nftables() {
  # try_packages (не die): если nftables не ставится — возвращаем ошибку, чтобы
  # firewall_setup переключился на ufw, а не уронил весь install.
  try_packages nftables \
    || { log_warn "nftables недоступен для установки — переключаюсь на ufw."; return 1; }
  systemctl enable nftables >/dev/null 2>&1 || true

  local -a tcp_ports udp_ports
  _firewall_collect_ports tcp_ports udp_ports

  # Дедуп TCP-портов (SSH мог совпасть с одним из сервисных).
  local -a tcp_uniq=() seen=()
  local p found
  for p in "${tcp_ports[@]}"; do
    found=0
    for s in "${seen[@]:-}"; do [[ "$s" == "$p" ]] && { found=1; break; }; done
    [[ $found -eq 0 ]] && { tcp_uniq+=("$p"); seen+=("$p"); }
  done

  local tcp_set udp_set
  tcp_set=$(IFS=,; printf '%s' "${tcp_uniq[*]}")
  udp_set=$(IFS=,; printf '%s' "${udp_ports[*]}")

  local conf=/etc/nftables-access.conf
  local ssh_port; ssh_port=$(firewall_detect_ssh_port)

  # Генерируем отдельную таблицу 'access' — не трогаем чужие правила.
  # Политика input drop, но СНАЧАЛА разрешаем established/related и loopback,
  # поэтому текущая SSH-сессия гарантированно переживает применение.
  {
    printf '#!/usr/sbin/nft -f\n'
    printf '# Сгенерировано access server. Не редактировать вручную.\n'
    printf 'table inet access {\n'
    printf '    chain input {\n'
    printf '        type filter hook input priority 0; policy drop;\n'
    printf '        ct state established,related accept\n'
    printf '        ct state invalid drop\n'
    printf '        iif "lo" accept\n'
    printf '        ip protocol icmp accept\n'
    printf '        ip6 nexthdr ipv6-icmp accept\n'
    # Живой SSH-порт первой строкой — подстраховка на случай гонки.
    printf '        tcp dport %s accept\n' "$ssh_port"
    [[ -n "$tcp_set" ]] && printf '        tcp dport { %s } accept\n' "$tcp_set"
    [[ -n "$udp_set" ]] && printf '        udp dport { %s } accept\n' "$udp_set"
    printf '    }\n'
    printf '    chain forward {\n'
    # Форвардинг разрешаем (трафик клиентов VPN ходит наружу).
    printf '        type filter hook forward priority 0; policy accept;\n'
    printf '    }\n'
    printf '}\n'
  } >"$conf" || { log_warn "Не удалось записать ${conf} — переключаюсь на ufw."; return 1; }

  # Проверяем синтаксис ДО применения — битый ruleset не должен ничего ломать.
  nft -c -f "$conf" >/dev/null 2>&1 \
    || { log_warn "Проверка nftables-конфига не прошла (nft -c) — переключаюсь на ufw. Файл: ${conf}"; return 1; }

  # Снимаем нашу старую таблицу (если была) и применяем заново — идемпотентно.
  nft delete table inet access >/dev/null 2>&1 || true
  nft -f "$conf" >/dev/null 2>&1 \
    || { log_warn "Не удалось применить nftables-правила — переключаюсь на ufw."; return 1; }

  # Подключаем наш файл к штатному /etc/nftables.conf, чтобы правила пережили ребут.
  local main=/etc/nftables.conf
  [[ -f "$main" ]] || printf '#!/usr/sbin/nft -f\nflush ruleset\n' >"$main"
  if ! grep -qF "include \"$conf\"" "$main" 2>/dev/null; then
    printf '\ninclude "%s"\n' "$conf" >>"$main"
  fi

  systemctl restart nftables >/dev/null 2>&1 || true
  log_ok "nftables: SSH(${ssh_port}/tcp), TCP{${tcp_set}}, UDP{${udp_set}} открыты, established сохранён."
}

# --- ufw (фолбэк) ------------------------------------------------------------
_firewall_setup_ufw() {
  ensure_packages ufw

  local -a tcp_ports udp_ports
  _firewall_collect_ports tcp_ports udp_ports
  local ssh_port; ssh_port=$(firewall_detect_ssh_port)

  # КРИТИЧНО: разрешаем SSH-порт ДО включения ufw, иначе default deny на input
  # оборвёт текущую сессию. ufw сам сохраняет established/related.
  ufw allow "${ssh_port}/tcp" >/dev/null 2>&1 \
    || die "ufw: не удалось разрешить SSH-порт ${ssh_port}."

  ufw default deny incoming >/dev/null 2>&1 || true
  ufw default allow outgoing >/dev/null 2>&1 || true
  # Форвардинг для клиентов VPN.
  ufw default allow routed >/dev/null 2>&1 || true

  local p
  for p in "${tcp_ports[@]}"; do
    ufw allow "${p}/tcp" >/dev/null 2>&1 || log_warn "ufw: не удалось открыть ${p}/tcp."
  done
  for p in "${udp_ports[@]}"; do
    ufw allow "${p}/udp" >/dev/null 2>&1 || log_warn "ufw: не удалось открыть ${p}/udp."
  done

  # --force: не задаём интерактивный вопрос про возможный обрыв SSH.
  ufw --force enable >/dev/null 2>&1 || die "ufw: не удалось включить фаервол."
  systemctl enable ufw >/dev/null 2>&1 || true

  local tcp_set udp_set
  tcp_set=$(IFS=,; printf '%s' "${tcp_ports[*]}")
  udp_set=$(IFS=,; printf '%s' "${udp_ports[*]}")
  log_ok "ufw: SSH(${ssh_port}/tcp), TCP{${tcp_set}}, UDP{${udp_set}} открыты."
}

# --- Публичная точка входа ---------------------------------------------------
firewall_setup() {
  log_step "Настройка фаервола"

  # Если ufw уже активен — продолжаем им, чтобы не плодить конфликтующие движки.
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
    log_info "Обнаружен активный ufw — настраиваем через ufw."
    _firewall_setup_ufw
    return 0
  fi

  # По умолчанию предпочитаем nftables.
  if command -v nft >/dev/null 2>&1 || apt-cache show nftables >/dev/null 2>&1; then
    if _firewall_setup_nftables; then
      return 0
    fi
    log_warn "nftables не удалось настроить — переключаюсь на ufw."
  fi

  _firewall_setup_ufw
}
