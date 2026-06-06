#!/usr/bin/env bash
# install.sh — главный установщик мульти-протокольного access-сервера.
# Четыре сервиса параллельно под systemd (без Docker):
#   AmneziaWG 2.0 (UDP), VLESS+Reality 443 (blacklist), VLESS+Reality 8443 (whitelist),
#   MTProto (mtg, fake-TLS). Опционально Hysteria2.
# Идемпотентно, неинтерактивно. Целевые ОС: Ubuntu 24.04 LTS, Debian 12. Запуск от root.
set -euo pipefail

# Репозиторий проекта (PUBLIC) — нужен для self-clone при curl-запуске standalone.
ACCESS_REPO_URL="https://github.com/PetrovSpace/universal-access.git"

# --- BOOTSTRAP: self-clone, если скрипт скачан в одиночку (curl | bash) -------
# Определяем каталог самого скрипта максимально надёжно.
_self_script_dir() {
  local src="${BASH_SOURCE[0]:-$0}" dir
  # Если запущено через `bash -c "$(curl ...)"`, BASH_SOURCE может быть пустым/некорректным.
  if [[ -z "$src" || "$src" == "bash" || "$src" == "-bash" || "$src" == "sh" ]]; then
    printf '%s' ''
    return 0
  fi
  dir=$(cd -- "$(dirname -- "$src")" >/dev/null 2>&1 && pwd -P) || dir=''
  printf '%s' "$dir"
}

_bootstrap_clone_and_exec() {
  # Нет lib/common.sh рядом -> скрипт скачан standalone. Клонируем репозиторий в SRC_DIR
  # (или git pull, если он уже там) и перезапускаем уже клонированный install.sh.
  local access_dir="${ACCESS_DIR:-/opt/access}"
  local src_dir="${SRC_DIR:-$access_dir/src}"

  # Минимальная проверка прав: клонирование в /opt требует root.
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    echo "[x] Требуются права root. Запустите от root (sudo)." >&2
    exit 1
  fi

  # git нужен для клонирования.
  if ! command -v git >/dev/null 2>&1; then
    echo "[*] Установка git..." >&2
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y >/dev/null 2>&1 || { echo "[x] apt-get update не удался." >&2; exit 1; }
    apt-get install -y --no-install-recommends git ca-certificates >/dev/null 2>&1 \
      || { echo "[x] Не удалось установить git." >&2; exit 1; }
  fi

  mkdir -p "$access_dir" || { echo "[x] Не удалось создать ${access_dir}." >&2; exit 1; }

  if [[ -d "$src_dir/.git" ]]; then
    echo "[*] Обновление репозитория в ${src_dir} (git pull)..." >&2
    git -C "$src_dir" pull --ff-only >/dev/null 2>&1 \
      || echo "[!] git pull не удался — используем текущую копию." >&2
  else
    echo "[*] Клонирование репозитория в ${src_dir}..." >&2
    rm -rf "$src_dir"
    git clone --depth 1 "$ACCESS_REPO_URL" "$src_dir" >/dev/null 2>&1 \
      || { echo "[x] Не удалось склонировать ${ACCESS_REPO_URL}." >&2; exit 1; }
  fi

  [[ -f "$src_dir/install.sh" ]] \
    || { echo "[x] В репозитории не найден install.sh (${src_dir}/install.sh)." >&2; exit 1; }
  [[ -f "$src_dir/lib/common.sh" ]] \
    || { echo "[x] В репозитории не найден lib/common.sh." >&2; exit 1; }

  echo "[+] Репозиторий готов — перезапуск клонированного install.sh." >&2
  export ACCESS_DIR="$access_dir" SRC_DIR="$src_dir"
  exec bash "$src_dir/install.sh" "$@"
}

# Резолвим директорию скрипта и решаем: bootstrap или нормальный запуск.
SCRIPT_DIR="$(_self_script_dir)"
if [[ -z "$SCRIPT_DIR" || ! -f "$SCRIPT_DIR/lib/common.sh" ]]; then
  _bootstrap_clone_and_exec "$@"
fi

# Отсюда мы запущены из клона репозитория: рядом есть lib/common.sh.
SRC_DIR="${SRC_DIR:-$SCRIPT_DIR}"
export SRC_DIR

# --- Подключение общего модуля и всех библиотек ------------------------------
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh" || { echo "[x] Не удалось подключить lib/common.sh." >&2; exit 1; }

for _mod in amneziawg xray mtproto firewall; do
  _modpath="$SCRIPT_DIR/lib/${_mod}.sh"
  [[ -f "$_modpath" ]] || die "Отсутствует модуль ${_modpath}."
  # shellcheck disable=SC1090
  source "$_modpath" || die "Не удалось подключить ${_modpath}."
done
unset _mod _modpath

# --- Опциональный Hysteria2 (определяется только если включён в конфиге) ------
_hysteria_install() {
  # Лёгкая интеграция Hysteria2: ставим официальным скриптом, генерим конфиг и ссылку.
  # Вызывается только при ENABLE_HYSTERIA2=true; не критично для основного флоу.
  log_step "Hysteria2 — установка (опционально)"

  # Порт UDP: при занятости сдвигаем.
  if ! is_port_free "${HYSTERIA2_PORT}" udp; then
    local newp; newp=$(find_free_port "${HYSTERIA2_PORT}" udp)
    log_warn "Порт ${HYSTERIA2_PORT}/udp занят — выбран ${newp}/udp."
    HYSTERIA2_PORT="$newp"; export HYSTERIA2_PORT
  fi

  ensure_packages curl ca-certificates openssl
  if ! command -v hysteria >/dev/null 2>&1; then
    log_info "Установка Hysteria2 через официальный скрипт..."
    bash -c "$(curl -fsSL https://get.hy2.sh/)" >/dev/null 2>&1 \
      || { log_warn "Не удалось установить Hysteria2 — пропускаю (основные сервисы не затронуты)."; return 0; }
  fi
  command -v hysteria >/dev/null 2>&1 \
    || { log_warn "Бинарь hysteria не найден после установки — пропускаю Hysteria2."; return 0; }

  # Пароль (общий) и самоподписанный TLS — идемпотентно через state.
  local hy_pass cert_dir cert key
  hy_pass=$(state_get_or_create hysteria2_password gen_hex 24)
  cert_dir=/etc/hysteria; cert="${cert_dir}/server.crt"; key="${cert_dir}/server.key"
  install -d -m 0700 "$cert_dir" 2>/dev/null || true
  if [[ ! -s "$cert" || ! -s "$key" ]]; then
    openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
      -keyout "$key" -out "$cert" -days 3650 \
      -subj "/CN=${MTPROTO_MASK_DOMAIN}" >/dev/null 2>&1 \
      || { log_warn "Не удалось создать TLS-сертификат для Hysteria2 — пропускаю."; return 0; }
    chmod 0600 "$key" "$cert" 2>/dev/null || true
  fi

  cat >"${cert_dir}/config.yaml" <<EOF
listen: :${HYSTERIA2_PORT}
tls:
  cert: ${cert}
  key: ${key}
auth:
  type: password
  password: ${hy_pass}
masquerade:
  type: proxy
  proxy:
    url: https://${MTPROTO_MASK_DOMAIN}/
    rewriteHost: true
EOF
  chmod 0600 "${cert_dir}/config.yaml" 2>/dev/null || true

  systemctl enable hysteria-server >/dev/null 2>&1 || true
  if systemctl restart hysteria-server >/dev/null 2>&1; then
    sleep 1
    systemctl is-active --quiet hysteria-server \
      && log_ok "Hysteria2 работает на ${PUBLIC_IP}:${HYSTERIA2_PORT}/udp." \
      || log_warn "Hysteria2 не активен после запуска — см. journalctl -u hysteria-server."
  else
    log_warn "Не удалось запустить hysteria-server — пропускаю."
    return 0
  fi

  # Клиентская ссылка hysteria2:// для каждого клиента (пароль общий).
  local client out
  for client in "${CLIENTS[@]}"; do
    out="${CLIENTS_DIR}/hysteria2-${client}.txt"
    {
      printf '# Hysteria2 — клиент: %s\n' "$client"
      printf '# Сервер: %s:%s/udp, маскировка под %s, insecure (самоподписанный TLS).\n\n' \
        "$PUBLIC_IP" "$HYSTERIA2_PORT" "$MTPROTO_MASK_DOMAIN"
      printf 'hysteria2://%s@%s:%s/?insecure=1&sni=%s#hysteria2-%s\n' \
        "$hy_pass" "$PUBLIC_IP" "$HYSTERIA2_PORT" "$MTPROTO_MASK_DOMAIN" "$client"
    } >"$out"
    chmod 0600 "$out" 2>/dev/null || true
    log_ok "Hysteria2 ссылка клиента '${client}': ${out}"
  done
}

# --- Сборка SUMMARY.txt + печать в stdout ------------------------------------
_write_summary() {
  local summary="${CLIENTS_DIR}/SUMMARY.txt"
  local ssh_port; ssh_port=$(firewall_detect_ssh_port)
  local tmp; tmp=$(mktemp) || die "mktemp не удался (summary)."

  {
    printf '==================================================================\n'
    printf '  ACCESS SERVER — ИТОГОВАЯ СВОДКА\n'
    printf '  Сервер: %s\n' "$PUBLIC_IP"
    printf '  ОС: %s %s | интерфейс: %s | SSH-порт: %s\n' \
      "${OS_ID:-?}" "${OS_VERSION_ID:-?}" "${DEFAULT_IFACE:-?}" "$ssh_port"
    printf '  Сгенерировано: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
    printf '==================================================================\n\n'

    printf 'ПОРТЫ И СЕРВИСЫ:\n'
    printf '  - VLESS+Reality gRPC  %s:%s/tcp  (ОСНОВНОЙ, SNI=%s) — обходит DPI РФ\n' \
      "$PUBLIC_IP" "${REALITY_PORT_GRPC:-2053}" "$(state_get xray_sni_blacklist)"
    printf '  - AmneziaWG 2.0       %s:%s/udp   (на сетях с открытым UDP)\n' "$PUBLIC_IP" "$AWG_PORT"
    printf '  - VLESS+Reality TCP   %s:%s/tcp   (ПЛАН Б blacklist, SNI=%s)\n' \
      "$PUBLIC_IP" "$REALITY_PORT_BLACKLIST" "$(state_get xray_sni_blacklist)"
    printf '  - VLESS+Reality TCP   %s:%s/tcp  (ПЛАН Б whitelist, SNI=%s)\n' \
      "$PUBLIC_IP" "$REALITY_PORT_WHITELIST" "$(state_get xray_sni_whitelist)"
    printf '  - MTProto (mtg)       %s:%s/tcp  (fake-TLS под %s)\n' \
      "$PUBLIC_IP" "${MTPROTO_PORT}" "$MTPROTO_MASK_DOMAIN"
    if [[ "${ENABLE_HYSTERIA2:-false}" == "true" ]]; then
      printf '  - Hysteria2           %s:%s/udp  (опционально)\n' "$PUBLIC_IP" "$HYSTERIA2_PORT"
    fi
    printf '\n'

    printf 'КАКОЙ ФАЙЛ -> В КАКОЕ ПРИЛОЖЕНИЕ:\n'
    printf '  vless-grpc-<client>.json   -> Happ (ОСНОВНОЙ): gRPC + split-routing (RU напрямую)\n'
    printf '  vless-grpc-<client>.txt    -> та же gRPC-ссылка без split-routing\n'
    printf '  vless-reality-<client>.txt -> ПЛАН Б: raw-TCP 443 (если gRPC встал)\n'
    printf '  vless-whitelist-<client>.txt -> ПЛАН Б: raw-TCP 8443 (моб. RU)\n'
    printf '  amneziawg-<peer>.conf      -> AmneziaWG (1 .conf = 1 устройство; нужен открытый UDP)\n'
    printf '  telegram-proxy-<client>.txt -> Telegram (tg:// + t.me/proxy)\n'
    if [[ "${ENABLE_HYSTERIA2:-false}" == "true" ]]; then
      printf '  hysteria2-<client>.txt     -> Hysteria2-клиент\n'
    fi
    printf '\n'

    # --- AmneziaWG: устройства (peers) ---
    printf -- '------------------------------------------------------------------\n'
    printf 'AMNEZIAWG — УСТРОЙСТВА (по одному .conf на устройство):\n'
    printf -- '------------------------------------------------------------------\n'
    local peer pconf
    for peer in "${AWG_PEERS[@]}"; do
      pconf="${CLIENTS_DIR}/amneziawg-${peer}.conf"
      printf '  [%s] %s\n' "$peer" "$pconf"
      printf '      scp -P %s root@%s:%s .\n' "$ssh_port" "$PUBLIC_IP" "$pconf"
    done
    printf '\n'

    # --- Клиенты: VLESS + Telegram (+Hysteria2) ---
    printf -- '------------------------------------------------------------------\n'
    printf 'КЛИЕНТЫ — ССЫЛКИ И ФАЙЛЫ:\n'
    printf -- '------------------------------------------------------------------\n'
    local client f_grpc f_bl f_wl f_tg f_hy link
    for client in "${CLIENTS[@]}"; do
      f_grpc="${CLIENTS_DIR}/vless-grpc-${client}.txt"
      f_bl="${CLIENTS_DIR}/vless-reality-${client}.txt"
      f_wl="${CLIENTS_DIR}/vless-whitelist-${client}.txt"
      f_tg="${CLIENTS_DIR}/telegram-proxy-${client}.txt"
      printf '\n=== Клиент: %s ===\n' "$client"

      printf '  VLESS gRPC (%s, ОСНОВНОЙ) — %s (+%s)\n' \
        "${REALITY_PORT_GRPC:-2053}" "$f_grpc" "${CLIENTS_DIR}/vless-grpc-${client}.json"
      link=$(grep -m1 '^vless://' "$f_grpc" 2>/dev/null || true)
      [[ -n "$link" ]] && printf '    %s\n' "$link"

      printf '  VLESS raw-TCP (blacklist, %s, ПЛАН Б) — %s\n' "$REALITY_PORT_BLACKLIST" "$f_bl"
      link=$(grep -m1 '^vless://' "$f_bl" 2>/dev/null || true)
      [[ -n "$link" ]] && printf '    %s\n' "$link"

      printf '  VLESS raw-TCP (whitelist, %s, ПЛАН Б) — %s\n' "$REALITY_PORT_WHITELIST" "$f_wl"
      link=$(grep -m1 '^vless://' "$f_wl" 2>/dev/null || true)
      [[ -n "$link" ]] && printf '    %s\n' "$link"

      printf '  Telegram MTProto — %s\n' "$f_tg"
      link=$(grep -m1 '^tg://proxy' "$f_tg" 2>/dev/null || true)
      [[ -n "$link" ]] && printf '    %s\n' "$link"
      link=$(grep -m1 '^https://t.me/proxy' "$f_tg" 2>/dev/null || true)
      [[ -n "$link" ]] && printf '    %s\n' "$link"

      if [[ "${ENABLE_HYSTERIA2:-false}" == "true" ]]; then
        f_hy="${CLIENTS_DIR}/hysteria2-${client}.txt"
        if [[ -f "$f_hy" ]]; then
          printf '  Hysteria2 — %s\n' "$f_hy"
          link=$(grep -m1 '^hysteria2://' "$f_hy" 2>/dev/null || true)
          [[ -n "$link" ]] && printf '    %s\n' "$link"
        fi
      fi
    done
    printf '\n'

    printf -- '------------------------------------------------------------------\n'
    printf 'СКАЧАТЬ ВСЁ ОДНОЙ КОМАНДОЙ:\n'
    printf '  scp -P %s root@%s:%s/* .\n' "$ssh_port" "$PUBLIC_IP" "$CLIENTS_DIR"
    printf '\nУПРАВЛЕНИЕ:\n'
    printf '  bin/info.sh                 — снова показать эту сводку\n'
    printf '  bin/regen.sh <client|peer>  — перевыпустить одного клиента/устройство\n'
    printf '  bin/set-sni.sh <blacklist|whitelist> <domain> — сменить SNI\n'
    printf '  bin/update.sh               — обновить Xray-core и AmneziaWG\n'
    printf '==================================================================\n'
  } >"$tmp"

  install -m 0600 "$tmp" "$summary" || die "Не удалось записать ${summary}."
  rm -f "$tmp"
  log_ok "Сводка сохранена: ${summary}"

  # Печатаем сводку в stdout (чистая, copy-paste).
  cat "$summary"
}

# --- Главный флоу ------------------------------------------------------------
main() {
  load_config
  require_root
  detect_os
  detect_public_ip
  detect_default_iface
  state_init

  log_step "Базовые пакеты и сетевой тюнинг"
  ensure_packages curl ca-certificates jq openssl uuid-runtime iproute2 gnupg tar

  enable_bbr
  tune_sysctl

  # Сервисы (каждый идемпотентен; только новые клиенты/пиры получают новые ключи).
  awg_install
  xray_install
  mtproto_install

  if [[ "${ENABLE_HYSTERIA2:-false}" == "true" ]]; then
    _hysteria_install
  fi

  # Фаервол ставим последним: открываем только нужные порты, не теряя SSH-сессию.
  firewall_setup

  # Итоговая сводка: файл + stdout.
  _write_summary

  log_ok "Установка завершена. Все артефакты в ${CLIENTS_DIR}."
}

main "$@"
