#!/usr/bin/env bash
# bin/info.sh — повторно печатает сводку доступа (SUMMARY).
# Если есть готовый CLIENTS_DIR/SUMMARY.txt — печатаем его как есть;
# иначе пересобираем сводку из состояния (STATE_DIR) и артефактов (CLIENTS_DIR).
set -euo pipefail

# --- Поиск корня репозитория и подключение common.sh ------------------------
# Скрипт лежит в bin/, корень репо — на уровень выше.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." >/dev/null 2>&1 && pwd -P)"

# В контракте install.sh кладёт исходники в SRC_DIR. Здесь же info.sh запускается
# из репозитория — поэтому источаем common.sh относительно корня репо.
COMMON_LIB="${REPO_ROOT}/lib/common.sh"
[[ -r "${COMMON_LIB}" ]] || { printf 'lib/common.sh не найден: %s\n' "${COMMON_LIB}" >&2; exit 1; }

# Чтобы load_config находил config.env рядом с репо, выставляем SRC_DIR на корень.
: "${SRC_DIR:=${REPO_ROOT}}"
export SRC_DIR

# shellcheck source=/dev/null
. "${COMMON_LIB}"
load_config

SUMMARY_FILE="${CLIENTS_DIR}/SUMMARY.txt"

# --- Печать готового SUMMARY, если он есть -----------------------------------
if [[ -f "${SUMMARY_FILE}" ]]; then
  cat "${SUMMARY_FILE}"
  exit 0
fi

# --- Иначе: пересборка сводки из state + CLIENTS_DIR -------------------------
log_warn "SUMMARY.txt не найден — пересобираю сводку из состояния."

# Публичный IP: из state install.sh не пишет напрямую, берём из конфигов/детекта.
ip="${PUBLIC_IP:-}"
if [[ -z "${ip}" ]]; then
  # Пытаемся вытащить Endpoint из любого клиентского AmneziaWG-конфига.
  awg_one=$(ls "${CLIENTS_DIR}"/amneziawg-*.conf 2>/dev/null | head -n1 || true)
  if [[ -n "${awg_one}" ]]; then
    ip=$(awk -F'[ =:]+' '/^Endpoint/{print $2; exit}' "${awg_one}" 2>/dev/null || true)
  fi
fi
[[ -z "${ip}" ]] && ip="<IP>"

# Порты: предпочитаем фактически применённые (сохранённые в state) значения.
mtproto_port="$(state_get mtproto_port)"
[[ -z "${mtproto_port}" ]] && mtproto_port="${MTPROTO_PORT}"
awg_port="$(state_get awg_port)"
[[ -z "${awg_port}" ]] && awg_port="${AWG_PORT}"

# SNI: предпочитаем сохранённые в state значения (фактически применённые).
sni_bl="$(state_get xray_sni_blacklist)"
[[ -z "${sni_bl}" ]] && sni_bl="${REALITY_SNI_BLACKLIST[0]:-?}"
sni_wl="$(state_get xray_sni_whitelist)"
[[ -z "${sni_wl}" ]] && sni_wl="${REALITY_SNI_WHITELIST[0]:-?}"

# Вспомогательная: первая «значимая» (не комментарий, не пустая) строка файла.
_first_payload_line() {
  local f="$1"
  [[ -f "${f}" ]] || return 1
  awk 'NF && $0 !~ /^[[:space:]]*#/ {print; exit}' "${f}" 2>/dev/null
}

# Вспомогательная: печать ссылки из файла или пометки об отсутствии.
_print_link() {
  local label="$1" file="$2" link
  if link="$(_first_payload_line "${file}")" && [[ -n "${link}" ]]; then
    printf '  %s\n    %s\n' "${label}" "${link}"
  else
    printf '  %s\n    (нет файла: %s)\n' "${label}" "${file}"
  fi
}

# --- Сборка текста сводки -----------------------------------------------------
{
  printf '======================================================================\n'
  printf ' UNIVERSAL ACCESS — СВОДКА ДОСТУПА (пересобрано info.sh)\n'
  printf '======================================================================\n'
  printf 'Сервер:        %s\n' "${ip}"
  printf 'AmneziaWG:     %s:%s/udp\n' "${ip}" "${awg_port}"
  printf 'VLESS Reality: %s:%s (blacklist, SNI %s)\n' "${ip}" "${REALITY_PORT_BLACKLIST}" "${sni_bl}"
  printf 'VLESS Reality: %s:%s (whitelist, SNI %s)\n' "${ip}" "${REALITY_PORT_WHITELIST}" "${sni_wl}"
  printf 'MTProto (TG):  %s:%s (маскировка %s)\n' "${ip}" "${mtproto_port}" "${MTPROTO_MASK_DOMAIN}"
  if [[ "${ENABLE_HYSTERIA2}" == "true" ]]; then
    printf 'Hysteria2:     %s:%s/udp\n' "${ip}" "${HYSTERIA2_PORT}"
  fi
  printf '\n'

  printf -- '--- AmneziaWG (UDP) — основной путь ----------------------------------\n'
  printf 'Приложение AmneziaWG. Один .conf = одно устройство, не шарьте конфиги.\n'
  for peer in "${AWG_PEERS[@]}"; do
    conf="${CLIENTS_DIR}/amneziawg-${peer}.conf"
    if [[ -f "${conf}" ]]; then
      printf '  [%s] %s\n' "${peer}" "${conf}"
    else
      printf '  [%s] (нет файла: %s)\n' "${peer}" "${conf}"
    fi
  done
  printf '\n'

  printf -- '--- VLESS + Reality :%s (blacklist) — для Happ ------------------------\n' "${REALITY_PORT_BLACKLIST}"
  printf 'Основной путь для приложения Happ (нейтральный иностранный SNI).\n'
  for client in "${CLIENTS[@]}"; do
    _print_link "[${client}]" "${CLIENTS_DIR}/vless-reality-${client}.txt"
  done
  printf '\n'

  printf -- '--- VLESS + Reality :%s (whitelist) — мобильные RU / ТСПУ -------------\n' "${REALITY_PORT_WHITELIST}"
  printf 'Переключайтесь сюда, когда основной перестаёт работать на мобильном.\n'
  for client in "${CLIENTS[@]}"; do
    _print_link "[${client}]" "${CLIENTS_DIR}/vless-whitelist-${client}.txt"
  done
  printf '\n'

  printf -- '--- Telegram MTProto-прокси ------------------------------------------\n'
  printf 'Откройте ссылку в Telegram (см. файл клиента целиком для t.me-зеркала).\n'
  for client in "${CLIENTS[@]}"; do
    _print_link "[${client}]" "${CLIENTS_DIR}/telegram-proxy-${client}.txt"
  done
  printf '\n'

  printf -- '--- Какой файл -> какое приложение -----------------------------------\n'
  printf '  amneziawg-<peer>.conf      -> AmneziaWG (импорт конфига)\n'
  printf '  vless-reality-<client>.txt -> Happ / VLESS-Reality (основной, :%s)\n' "${REALITY_PORT_BLACKLIST}"
  printf '  vless-whitelist-<client>.txt -> VLESS-Reality (запасной, :%s)\n' "${REALITY_PORT_WHITELIST}"
  printf '  telegram-proxy-<client>.txt -> Telegram (MTProto-прокси)\n'
  printf '\n'

  printf -- '--- Команды копирования (scp) ----------------------------------------\n'
  ssh_user="${SUDO_USER:-root}"
  for peer in "${AWG_PEERS[@]}"; do
    printf '  scp %s@%s:%s/amneziawg-%s.conf .\n' "${ssh_user}" "${ip}" "${CLIENTS_DIR}" "${peer}"
  done
  for client in "${CLIENTS[@]}"; do
    printf '  scp %s@%s:%s/vless-reality-%s.txt .\n' "${ssh_user}" "${ip}" "${CLIENTS_DIR}" "${client}"
    printf '  scp %s@%s:%s/vless-whitelist-%s.txt .\n' "${ssh_user}" "${ip}" "${CLIENTS_DIR}" "${client}"
    printf '  scp %s@%s:%s/telegram-proxy-%s.txt .\n' "${ssh_user}" "${ip}" "${CLIENTS_DIR}" "${client}"
  done
  printf '\n'
  printf 'Каталог клиентских файлов: %s\n' "${CLIENTS_DIR}"
  printf '======================================================================\n'
} || die "Не удалось сформировать сводку."
