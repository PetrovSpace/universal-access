#!/usr/bin/env bash
# lib/amneziawg.sh — установка и настройка AmneziaWG 2.0 (основной UDP-путь).
# Источается после common.sh. Определяет awg_install (см. контракт).
# Цепочка фолбэка: dkms -> linux-headers -> userspace amneziawg-go (install НЕ прерывается).
set -euo pipefail

# --- Константы модуля --------------------------------------------------------
AWG_CONF_DIR="/etc/amnezia/amneziawg"
AWG_IFACE="awg0"
AWG_CONF="${AWG_CONF_DIR}/${AWG_IFACE}.conf"
AWG_GO_REPO="https://github.com/amnezia-vpn/amneziawg-go.git"

# --- Подключение PPA Amnezia (idempotent) ------------------------------------
_awg_add_repo() {
  # Ubuntu: официальный PPA ppa:amnezia/ppa.
  # Debian: PPA недоступен — полагаемся на amneziawg-go (userspace), репо не добавляем.
  if [[ "${OS_ID:-}" != "ubuntu" ]]; then
    log_info "Debian: PPA Amnezia не используется, путь — userspace amneziawg-go."
    return 1
  fi
  if compgen -G '/etc/apt/sources.list.d/*amnezia*' >/dev/null 2>&1; then
    log_info "PPA Amnezia уже подключён."
    return 0
  fi
  ensure_packages software-properties-common gnupg ca-certificates
  log_info "Подключение PPA Amnezia (ppa:amnezia/ppa)..."
  if DEBIAN_FRONTEND=noninteractive add-apt-repository -y ppa:amnezia/ppa >/dev/null 2>&1; then
    _APT_UPDATED=0   # форсируем повторный apt-get update с новым репо
    log_ok "PPA Amnezia подключён."
    return 0
  fi
  log_warn "Не удалось подключить PPA Amnezia — переключаемся на userspace amneziawg-go."
  return 1
}

# --- Проверка работоспособности ядерного модуля ------------------------------
_awg_kmod_ok() {
  # 0, если ядерный модуль amneziawg грузится.
  modprobe amneziawg 2>/dev/null || true
  [[ -d /sys/module/amneziawg ]] && return 0
  modinfo amneziawg >/dev/null 2>&1 && modprobe amneziawg 2>/dev/null && [[ -d /sys/module/amneziawg ]]
}

# --- Установка userspace-реализации amneziawg-go (фолбэк) --------------------
_awg_install_go() {
  # Ставим бинарь amneziawg-go в /usr/bin. awg-quick подхватит его автоматически,
  # если ядерного модуля нет (WG_QUICK_USERSPACE_IMPLEMENTATION по умолчанию = amneziawg-go).
  if command -v amneziawg-go >/dev/null 2>&1; then
    log_ok "amneziawg-go уже установлен: $(command -v amneziawg-go)"
    return 0
  fi
  log_step "Сборка userspace amneziawg-go (фолбэк)"
  ensure_packages git make golang-go
  local build_dir; build_dir="${SRC_DIR}/amneziawg-go"
  if [[ -d "${build_dir}/.git" ]]; then
    git -C "${build_dir}" pull --ff-only >/dev/null 2>&1 || true
  else
    rm -rf "${build_dir}"
    git clone --depth 1 "${AWG_GO_REPO}" "${build_dir}" >/dev/null 2>&1 \
      || die "Не удалось клонировать amneziawg-go."
  fi
  log_info "Компиляция amneziawg-go (может занять минуту)..."
  if ! make -C "${build_dir}" >/dev/null 2>&1; then
    die "Сборка amneziawg-go провалилась. Проверьте версию Go (нужна свежая)."
  fi
  make -C "${build_dir}" install >/dev/null 2>&1 \
    || install -v -m 0755 "${build_dir}/amneziawg-go" /usr/bin/amneziawg-go >/dev/null 2>&1 \
    || die "Не удалось установить бинарь amneziawg-go в /usr/bin."
  command -v amneziawg-go >/dev/null 2>&1 \
    || die "amneziawg-go не найден в PATH после установки."
  log_ok "amneziawg-go установлен: $(command -v amneziawg-go)"
}

# --- Установка пакетов AmneziaWG с цепочкой фолбэка ---------------------------
_awg_install_packages() {
  # Цель: рабочие awg/awg-quick + работающий датаплейн (ядерный модуль ЛИБО amneziawg-go).
  local repo_ok=0
  _awg_add_repo && repo_ok=1 || repo_ok=0

  # amneziawg-tools (awg, awg-quick) нужны в любом случае.
  if [[ $repo_ok -eq 1 ]]; then
    if ! try_packages amneziawg-tools; then
      log_warn "Пакет amneziawg-tools недоступен из репо — будет userspace-сборка инструментов недоступна, пробуем dkms-путь."
    fi
  fi

  # Шаг 1: пробуем ядерный модуль через DKMS (только если есть репо).
  if [[ $repo_ok -eq 1 ]]; then
    log_step "Установка ядерного модуля AmneziaWG (DKMS)"
    if try_packages amneziawg-dkms && _awg_kmod_ok; then
      log_ok "Ядерный модуль AmneziaWG собран и загружен (DKMS)."
      command -v awg-quick >/dev/null 2>&1 || die "awg-quick не найден после установки amneziawg-tools."
      return 0
    fi

    # Шаг 2: типичная причина на Ubuntu 24.04 — нет заголовков ядра. Ставим и пересобираем DKMS.
    log_warn "Сборка DKMS не удалась — ставим заголовки ядра и пересобираем."
    try_packages "linux-headers-$(uname -r)" dkms \
      || log_warn "Не удалось поставить linux-headers-$(uname -r) (возможно нужен generic-метапакет)."
    try_packages linux-headers-generic || true
    # Принудительная пересборка модуля DKMS, если пакет dkms знает о нём.
    if command -v dkms >/dev/null 2>&1; then
      # ВАЖНО: НЕ `dkms status | awk …exit` — awk закрывает пайп рано, dkms ловит
      # SIGPIPE, и под pipefail+set -e скрипт молча падает (dkms status многострочный).
      # Захватываем вывод, парсим через here-string — пайпа нет, SIGPIPE невозможен.
      local ver dkms_st
      dkms_st=$(dkms status 2>/dev/null) || dkms_st=''
      ver=$(awk -F'[,/ ]+' '/amneziawg/{print $2; exit}' <<<"$dkms_st")
      if [[ -n "${ver:-}" ]]; then
        dkms autoinstall >/dev/null 2>&1 || dkms install -m amneziawg -v "${ver}" >/dev/null 2>&1 || true
      fi
    fi
    if _awg_kmod_ok; then
      log_ok "Ядерный модуль AmneziaWG собран после установки заголовков."
      command -v awg-quick >/dev/null 2>&1 || die "awg-quick не найден после установки amneziawg-tools."
      return 0
    fi
    log_warn "Ядерный модуль так и не собрался — переходим на userspace amneziawg-go."
  fi

  # Шаг 3 (фолбэк): userspace amneziawg-go. install НЕ прерываем.
  _awg_install_go

  # На Debian/без-PPA пакет amneziawg-tools мог не поставиться — соберём инструменты из исходников.
  if ! command -v awg-quick >/dev/null 2>&1; then
    _awg_install_tools_from_src
  fi
  command -v awg-quick >/dev/null 2>&1 \
    || die "awg-quick недоступен даже после userspace-фолбэка."
  log_ok "AmneziaWG работает через userspace amneziawg-go."
}

# --- Сборка amneziawg-tools из исходников (когда нет пакета) ------------------
_awg_install_tools_from_src() {
  command -v awg-quick >/dev/null 2>&1 && return 0
  log_step "Сборка amneziawg-tools из исходников"
  ensure_packages git make gcc
  local d; d="${SRC_DIR}/amneziawg-tools"
  if [[ -d "${d}/.git" ]]; then
    git -C "${d}" pull --ff-only >/dev/null 2>&1 || true
  else
    rm -rf "${d}"
    git clone --depth 1 https://github.com/amnezia-vpn/amneziawg-tools.git "${d}" >/dev/null 2>&1 \
      || die "Не удалось клонировать amneziawg-tools."
  fi
  make -C "${d}/src" >/dev/null 2>&1 || die "Сборка amneziawg-tools провалилась."
  make -C "${d}/src" install >/dev/null 2>&1 || die "Установка amneziawg-tools провалилась."
  command -v awg-quick >/dev/null 2>&1 || die "awg-quick не найден после сборки из исходников."
  log_ok "amneziawg-tools собраны и установлены."
}

# --- Ключи сервера (идемпотентно через state) --------------------------------
_awg_server_keys() {
  # Приватный ключ сервера — один раз, дальше переиспользуем.
  AWG_SRV_PRIV=$(state_get_or_create awg_server_private _awg_genkey)
  [[ -n "${AWG_SRV_PRIV}" ]] || die "Пустой приватный ключ сервера AmneziaWG."
  AWG_SRV_PUB=$(printf '%s' "${AWG_SRV_PRIV}" | awg pubkey 2>/dev/null) \
    || die "Не удалось вычислить публичный ключ сервера AmneziaWG."
  [[ -n "${AWG_SRV_PUB}" ]] || die "Пустой публичный ключ сервера AmneziaWG."
}

_awg_genkey() { awg genkey; }

# --- Адресация сервера/пиров из AWG_SUBNET -----------------------------------
_awg_net_setup() {
  # Из AWG_SUBNET (CIDR) выводим базу /24 и маску. Сервер = .1.
  local cidr="${AWG_SUBNET}"
  AWG_MASK="${cidr##*/}"
  local base="${cidr%/*}"
  AWG_NET_PREFIX="${base%.*}"               # напр. 10.13.13
  AWG_SRV_IP="${AWG_NET_PREFIX}.1"
}

# --- Стабильный UDP-порт сервера (идемпотентно через state) ------------------
_awg_resolve_port() {
  # Порт ДОЛЖЕН быть детерминирован между ранами: клиентские .conf пишут
  # Endpoint=PUBLIC_IP:AWG_PORT, а сервер слушает ListenPort=AWG_PORT.
  # Логика:
  #   1) если порт сохранён в state — переиспользуем его (а не дефолт/env);
  #   2) автосдвиг ТОЛЬКО когда нет сохранённого порта, либо сохранённый порт
  #      реально занят другим процессом;
  #   3) финальный порт сохраняем в state, чтобы реран был стабилен.
  local saved
  saved=$(state_get awg_port)

  if [[ -n "${saved}" ]]; then
    AWG_PORT="${saved}"
    if is_port_free "${AWG_PORT}" udp; then
      log_info "AmneziaWG: используем сохранённый порт ${AWG_PORT}/udp."
    else
      # Порт занят: это может быть наш собственный уже поднятый интерфейс.
      # Если awg0 активен — порт занимаем мы сами, оставляем как есть.
      if systemctl is-active --quiet "awg-quick@${AWG_IFACE}" 2>/dev/null; then
        log_info "AmneziaWG: порт ${AWG_PORT}/udp занят нашим интерфейсом ${AWG_IFACE} — оставляем."
      else
        local newp; newp=$(find_free_port "${AWG_PORT}" udp)
        log_warn "AmneziaWG: сохранённый порт ${AWG_PORT}/udp занят другим процессом — выбран ${newp}/udp."
        AWG_PORT="${newp}"
      fi
    fi
  else
    # Первый запуск: берём дефолт/env, при занятости сдвигаемся.
    if ! is_port_free "${AWG_PORT}" udp; then
      local newp; newp=$(find_free_port "${AWG_PORT}" udp)
      log_warn "AmneziaWG: порт ${AWG_PORT}/udp занят — выбран свободный ${newp}/udp."
      AWG_PORT="${newp}"
    fi
  fi

  # Фиксируем порт в state — дальнейшие раны будут стабильны.
  state_set awg_port "${AWG_PORT}"
  export AWG_PORT
}

# --- Следующий свободный IP пира (стабильно через state) ---------------------
_awg_peer_ip() {
  # Назначаем пиру фиксированный IP и СОХРАНЯЕМ его, чтобы реран не менял адреса.
  local peer="$1" key="awg_peer_ip_${1}" ip
  ip=$(state_get "${key}")
  if [[ -n "${ip}" ]]; then
    printf '%s' "${ip}"
    return 0
  fi
  # Ищем минимальный свободный хост-октет (>=2), не занятый другими пирами.
  local used octet candidate f
  used=" ${AWG_SRV_IP##*.} "
  for f in "${STATE_DIR}"/awg_peer_ip_*; do
    [[ -e "${f}" ]] || continue
    used+="$(cat "${f}" 2>/dev/null | awk -F. '{print $4}') "
  done
  for ((octet=2; octet<=254; octet++)); do
    case " ${used} " in *" ${octet} "*) continue ;; esac
    candidate="${AWG_NET_PREFIX}.${octet}"
    state_set "${key}" "${candidate}"
    printf '%s' "${candidate}"
    return 0
  done
  die "Закончились адреса в подсети ${AWG_SUBNET} для пиров AmneziaWG."
}

# --- Блок [Interface]-обфускации AmneziaWG 2.0 (общий для сервера и клиентов) -
_awg_obfuscation_block() {
  # Печатает строки Jc/Jmin/Jmax/S1/S2/H1..H4 (+ I1..I5, если заданы в config.env).
  printf 'Jc = %s\n'   "${AWG_JC}"
  printf 'Jmin = %s\n' "${AWG_JMIN}"
  printf 'Jmax = %s\n' "${AWG_JMAX}"
  printf 'S1 = %s\n'   "${AWG_S1}"
  printf 'S2 = %s\n'   "${AWG_S2}"
  printf 'H1 = %s\n'   "${AWG_H1}"
  printf 'H2 = %s\n'   "${AWG_H2}"
  printf 'H3 = %s\n'   "${AWG_H3}"
  printf 'H4 = %s\n'   "${AWG_H4}"
  # Параметры мимикрии AmneziaWG 2.0 (I1..I5) — только если непустые,
  # пустые значения ломают awg-quick (см. amneziawg-tools issue #40).
  local v
  for v in 1 2 3 4 5; do
    local name="AWG_I${v}" val
    val="${!name:-}"
    [[ -n "${val}" ]] && printf 'I%s = %s\n' "${v}" "${val}"
  done
}

# --- Генерация серверного awg0.conf из state ---------------------------------
_awg_write_server_conf() {
  # Полная перезапись awg0.conf из сохранённого состояния — идемпотентно.
  mkdir -p "${AWG_CONF_DIR}" || die "Не удалось создать ${AWG_CONF_DIR}."
  chmod 0700 "${AWG_CONF_DIR}" || true

  local tmp; tmp=$(mktemp) || die "mktemp не удался."
  {
    printf '# AmneziaWG server config — сгенерирован автоматически, правки перезапишутся.\n'
    printf '[Interface]\n'
    printf 'Address = %s/%s\n' "${AWG_SRV_IP}" "${AWG_MASK}"
    printf 'ListenPort = %s\n' "${AWG_PORT}"
    printf 'PrivateKey = %s\n' "${AWG_SRV_PRIV}"
    printf 'MTU = %s\n' "${AWG_MTU}"
    _awg_obfuscation_block
    # NAT/форвардинг на основной интерфейс (датаплейн наружу).
    printf 'PostUp = iptables -A FORWARD -i %%i -j ACCEPT; iptables -A FORWARD -o %%i -j ACCEPT; iptables -t nat -A POSTROUTING -s %s -o %s -j MASQUERADE\n' \
      "${AWG_SUBNET}" "${DEFAULT_IFACE}"
    printf 'PostDown = iptables -D FORWARD -i %%i -j ACCEPT; iptables -D FORWARD -o %%i -j ACCEPT; iptables -t nat -D POSTROUTING -s %s -o %s -j MASQUERADE\n' \
      "${AWG_SUBNET}" "${DEFAULT_IFACE}"
    printf '\n'
    # Пиры: один [Peer] на устройство, ключи из state.
    local peer pub ip
    for peer in "${AWG_PEERS[@]}"; do
      pub=$(state_get "awg_peer_pub_${peer}")
      ip=$(state_get "awg_peer_ip_${peer}")
      [[ -n "${pub}" && -n "${ip}" ]] || continue
      printf '# peer: %s\n' "${peer}"
      printf '[Peer]\n'
      printf 'PublicKey = %s\n' "${pub}"
      printf 'PresharedKey = %s\n' "$(state_get "awg_peer_psk_${peer}")"
      printf 'AllowedIPs = %s/32\n\n' "${ip}"
    done
  } >"${tmp}"

  install -m 0600 "${tmp}" "${AWG_CONF}" || die "Не удалось записать ${AWG_CONF}."
  rm -f "${tmp}"
  log_ok "Серверный конфиг записан: ${AWG_CONF}"
}

# --- Генерация/обновление одного пира (ключи + клиентский .conf) -------------
_awg_ensure_peer() {
  local peer="$1"
  # Имя пира должно быть безопасным для имени файла/ключа state.
  [[ "${peer}" =~ ^[A-Za-z0-9._-]+$ ]] || die "Недопустимое имя пира: '${peer}'."

  # Приватный ключ пира — идемпотентно. Реран существующего пира НЕ перевыпускает ключ.
  local priv pub psk ip
  priv=$(state_get_or_create "awg_peer_private_${peer}" _awg_genkey)
  [[ -n "${priv}" ]] || die "Пустой приватный ключ пира '${peer}'."
  pub=$(printf '%s' "${priv}" | awg pubkey 2>/dev/null) \
    || die "Не удалось вычислить публичный ключ пира '${peer}'."
  state_set "awg_peer_pub_${peer}" "${pub}"
  psk=$(state_get_or_create "awg_peer_psk_${peer}" awg genpsk)
  [[ -n "${psk}" ]] || die "Пустой PSK пира '${peer}'."
  ip=$(_awg_peer_ip "${peer}")

  # Клиентский нативный AmneziaWG .conf — работает ровно на ОДНОМ устройстве.
  local out="${CLIENTS_DIR}/amneziawg-${peer}.conf"
  local tmp; tmp=$(mktemp) || die "mktemp не удался."
  {
    printf '# AmneziaWG client config для устройства: %s\n' "${peer}"
    printf '# Импортировать в приложении AmneziaWG. Один .conf = одно устройство.\n'
    printf '[Interface]\n'
    printf 'Address = %s/32\n' "${ip}"
    printf 'PrivateKey = %s\n' "${priv}"
    printf 'DNS = 1.1.1.1, 8.8.8.8\n'
    printf 'MTU = %s\n' "${AWG_MTU}"
    _awg_obfuscation_block
    printf '\n[Peer]\n'
    printf 'PublicKey = %s\n' "${AWG_SRV_PUB}"
    printf 'PresharedKey = %s\n' "${psk}"
    printf 'AllowedIPs = 0.0.0.0/0, ::/0\n'
    printf 'Endpoint = %s:%s\n' "${PUBLIC_IP}" "${AWG_PORT}"
    printf 'PersistentKeepalive = 25\n'
  } >"${tmp}"
  install -m 0600 "${tmp}" "${out}" || die "Не удалось записать ${out}."
  rm -f "${tmp}"
  log_ok "Пир '${peer}': IP ${ip}, конфиг ${out}"
}

# --- Запуск/перезапуск сервиса awg-quick@awg0 --------------------------------
_awg_start_service() {
  systemctl enable "awg-quick@${AWG_IFACE}" >/dev/null 2>&1 \
    || log_warn "Не удалось включить автозапуск awg-quick@${AWG_IFACE}."
  # Полный рестарт интерфейса, чтобы подхватить изменённый конфиг идемпотентно.
  if systemctl is-active --quiet "awg-quick@${AWG_IFACE}"; then
    systemctl restart "awg-quick@${AWG_IFACE}" >/dev/null 2>&1 \
      || die "Не удалось перезапустить awg-quick@${AWG_IFACE}. См. journalctl -u awg-quick@${AWG_IFACE}."
  else
    systemctl start "awg-quick@${AWG_IFACE}" >/dev/null 2>&1 \
      || die "Не удалось запустить awg-quick@${AWG_IFACE}. См. journalctl -u awg-quick@${AWG_IFACE}."
  fi
  systemctl is-active --quiet "awg-quick@${AWG_IFACE}" \
    || die "Сервис awg-quick@${AWG_IFACE} не активен после запуска."
  log_ok "Интерфейс ${AWG_IFACE} поднят (порт ${AWG_PORT}/udp)."
}

# --- ПУБЛИЧНАЯ ФУНКЦИЯ: полная установка AmneziaWG ---------------------------
awg_install() {
  log_step "AmneziaWG 2.0 — установка и настройка"

  # 0) Порт: стабильный между ранами через state (см. _awg_resolve_port).
  #    На рестарте интерфейс уже может слушать сохранённый порт — это не повод
  #    его сдвигать, иначе ранее выданные клиентские .conf перестанут совпадать.
  _awg_resolve_port

  # 1) Пакеты + датаплейн с цепочкой фолбэка (никогда не прерывает install).
  _awg_install_packages

  # 2) Сетевые параметры и ключи сервера (идемпотентно).
  _awg_net_setup
  _awg_server_keys

  # 3) Пиры: только недостающие получают новые ключи; существующие не трогаем.
  local peer
  for peer in "${AWG_PEERS[@]}"; do
    _awg_ensure_peer "${peer}"
  done

  # 4) Серверный конфиг из state и запуск сервиса.
  _awg_write_server_conf
  _awg_start_service

  log_ok "AmneziaWG готов: ${PUBLIC_IP}:${AWG_PORT}/udp, пиров: ${#AWG_PEERS[@]}."
}
