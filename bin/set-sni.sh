#!/usr/bin/env bash
# bin/set-sni.sh — быстрая смена SNI для одного Reality-режима.
# Использование: set-sni.sh <blacklist|whitelist> <domain>
# Валидирует домен (TLS 1.3 + HTTP/2), применяет к нужному inbound'у и перезапускает Xray.
set -euo pipefail

# --- Путь к репозиторию относительно этого скрипта ---------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# SRC_DIR указывает на корень репозитория, чтобы load_config нашёл config.env.
export SRC_DIR="${REPO_ROOT}"

# --- Подключение общих функций и модуля Xray ---------------------------------
# shellcheck source=/dev/null
. "${REPO_ROOT}/lib/common.sh" || { echo "Не найден lib/common.sh рядом со скриптом." >&2; exit 1; }
# shellcheck source=/dev/null
. "${REPO_ROOT}/lib/xray.sh" || die "Не найден lib/xray.sh в ${REPO_ROOT}/lib."

# --- Подсказка по использованию ----------------------------------------------
_usage() {
  cat >&2 <<EOF
Использование: $(basename "$0") <blacklist|whitelist> <domain>

  blacklist  — основной inbound :${REALITY_PORT_BLACKLIST:-443} (нейтральный иностранный SNI).
  whitelist  — мобильный inbound :${REALITY_PORT_WHITELIST:-8443} (разрешённый RU-ресурс).

Домен обязан отдавать TLS 1.3 и HTTP/2 — иначе он будет отклонён.
Пример: $(basename "$0") blacklist www.cloudflare.com
EOF
}

main() {
  local mode="${1:-}" domain="${2:-}"

  # Проверка аргументов до загрузки конфигурации (для понятного usage).
  if [[ -z "$mode" || -z "$domain" ]]; then
    _usage
    die "Нужны два аргумента: режим (blacklist|whitelist) и домен."
  fi
  case "$mode" in
    blacklist|whitelist) ;;
    *) _usage; die "Неизвестный режим '${mode}'. Допустимо: blacklist|whitelist." ;;
  esac

  # Окружение: конфиг, root, базовые определения, каталоги состояния.
  load_config
  require_root
  detect_os
  detect_public_ip
  state_init

  log_step "Смена SNI режима '${mode}' на '${domain}'"

  # Валидация домена (TLS 1.3 + HTTP/2). При провале — стоп, рабочий конфиг не трогаем.
  if ! xray_validate_sni "$domain"; then
    die "Домен '${domain}' не подходит (требуются TLS 1.3 и HTTP/2). SNI не изменён."
  fi

  # Применение: xray_apply_sni сам перепишет нужный inbound, протестирует
  # конфиг (xray run -test), перезапустит сервис и обновит клиентские ссылки.
  xray_apply_sni "$mode" "$domain"

  log_ok "Готово: SNI режима '${mode}' установлен в '${domain}', Xray перезапущен."
}

main "$@"
