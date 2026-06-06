#!/usr/bin/env bash
# bin/regen.sh — перевыпуск ключей ровно для ОДНОГО клиента или AWG-пира.
#   regen.sh <client|peer>
# Удаляет только state-ключи указанной сущности, затем заново запускает
# соответствующий *_install (он идемпотентен: тронет только отсутствующие
# ключи, т.е. именно перевыпущенную сущность), и перезапускает сервис.
# Остальные клиенты/пиры остаются нетронутыми.
set -euo pipefail

# --- Резолвинг корня репозитория относительно этого скрипта ------------------
# REPO_ROOT = каталог bin/.. ; модули и config.env лежат там же.
_self="${BASH_SOURCE[0]}"
while [[ -L "$_self" ]]; do
  _dir="$(cd -P "$(dirname "$_self")" >/dev/null 2>&1 && pwd)"
  _self="$(readlink "$_self")"
  if [[ "$_self" != /* ]]; then _self="${_dir}/${_self}"; fi
done
BIN_DIR="$(cd -P "$(dirname "$_self")" >/dev/null 2>&1 && pwd)"
REPO_ROOT="$(cd -P "${BIN_DIR}/.." >/dev/null 2>&1 && pwd)"

# common.sh выставляет пути/цвета и функции; SRC_DIR используется load_config.
# Привязываем SRC_DIR к корню репозитория, чтобы load_config нашёл config.env.
export SRC_DIR="${SRC_DIR:-$REPO_ROOT}"

# --- Подключение модулей -----------------------------------------------------
# shellcheck source=/dev/null
. "${REPO_ROOT}/lib/common.sh"  || { echo "Не найден lib/common.sh рядом с bin/" >&2; exit 1; }
# shellcheck source=/dev/null
. "${REPO_ROOT}/lib/amneziawg.sh" || die "Не найден lib/amneziawg.sh."
# shellcheck source=/dev/null
. "${REPO_ROOT}/lib/xray.sh"      || die "Не найден lib/xray.sh."
# shellcheck source=/dev/null
. "${REPO_ROOT}/lib/mtproto.sh"   || die "Не найден lib/mtproto.sh."

# --- Удаление одного state-ключа (с той же защитой имени, что в common.sh) ----
_regen_drop_state() {
  # Удаляет файл STATE_DIR/<key>, если он существует. Безопасно для повторов.
  local key="$1" f
  case "$key" in
    */*|.*) die "Недопустимое имя ключа состояния: '${key}'." ;;
  esac
  f="${STATE_DIR}/${key}"
  if [[ -f "$f" ]]; then
    rm -f "$f" || die "Не удалось удалить state-ключ '${key}'."
    log_info "Сброшен state-ключ: ${key}"
  fi
}

# --- Принадлежность имени массиву CLIENTS / AWG_PEERS ------------------------
_regen_in_array() {
  # _regen_in_array NAME ELEM... -> 0, если NAME присутствует среди ELEM.
  local needle="$1"; shift
  local e
  for e in "$@"; do
    [[ "$e" == "$needle" ]] && return 0
  done
  return 1
}

# --- Перевыпуск клиента (VLESS UUID + MTProto secret) ------------------------
_regen_client() {
  local name="$1"
  log_step "Перевыпуск клиента '${name}' (VLESS UUID + MTProto secret)"

  # Сбрасываем per-client VLESS UUID (изолированно — у других клиентов свой UUID).
  # MTProto-секрет в mtg v2 ОБЩИЙ для всех клиентов, его ротация затрагивает всех:
  # предупреждаем и перевыпускаем общий секрет (Telegram-ссылки всех обновятся).
  _regen_drop_state "xray_uuid_${name}"
  log_warn "MTProto-секрет общий для всех клиентов (ограничение mtg v2) — он будет перевыпущен для ВСЕХ."
  _regen_drop_state "mtproto_secret"

  # Заодно удаляем устаревшие клиентские артефакты — *_install перезапишет их
  # уже с новыми значениями для этого клиента.
  rm -f "${CLIENTS_DIR}/vless-grpc-${name}.txt" \
        "${CLIENTS_DIR}/vless-grpc-${name}.json" \
        "${CLIENTS_DIR}/vless-reality-${name}.txt" \
        "${CLIENTS_DIR}/vless-whitelist-${name}.txt" \
        "${CLIENTS_DIR}/telegram-proxy-${name}.txt" 2>/dev/null || true

  # Идемпотентные установщики: вновь сгенерируют только удалённые ключи,
  # пересоберут config и перезапустят сервисы (xray, mtg).
  xray_install
  mtproto_install

  log_ok "Клиент '${name}' перевыпущен. Основной: ${CLIENTS_DIR}/vless-grpc-${name}.txt (+.json). План Б: ${CLIENTS_DIR}/vless-reality-${name}.txt, ${CLIENTS_DIR}/vless-whitelist-${name}.txt. TG: ${CLIENTS_DIR}/telegram-proxy-${name}.txt"
}

# --- Перевыпуск AWG-пира (ключи устройства) ----------------------------------
_regen_peer() {
  local name="$1"
  log_step "Перевыпуск AmneziaWG-пира '${name}' (ключи устройства)"

  # Сбрасываем ТОЛЬКО ключи этого пира. IP тоже сбрасываем — пир получит
  # новый адрес из свободных; адреса других пиров остаются за ними.
  _regen_drop_state "awg_peer_private_${name}"
  _regen_drop_state "awg_peer_pub_${name}"
  _regen_drop_state "awg_peer_psk_${name}"
  _regen_drop_state "awg_peer_ip_${name}"

  # Удаляем старый клиентский .conf — awg_install перезапишет его новыми ключами.
  rm -f "${CLIENTS_DIR}/amneziawg-${name}.conf" 2>/dev/null || true

  # Идемпотентная установка: ключи сервера и других пиров не меняются,
  # отсутствующий пир получает новые ключи, конфиг сервера и сервис обновляются.
  awg_install

  log_ok "Пир '${name}' перевыпущен. Файл: ${CLIENTS_DIR}/amneziawg-${name}.conf"
}

# --- main --------------------------------------------------------------------
main() {
  load_config
  require_root
  detect_os
  detect_public_ip
  detect_default_iface
  state_init

  local name="${1:-}"
  [[ -n "$name" ]] || die "Использование: regen.sh <client|peer>"
  [[ "$name" =~ ^[A-Za-z0-9._-]+$ ]] || die "Недопустимое имя сущности: '${name}'."

  local is_client=0 is_peer=0
  _regen_in_array "$name" "${CLIENTS[@]}"   && is_client=1 || true
  _regen_in_array "$name" "${AWG_PEERS[@]}" && is_peer=1   || true

  if [[ $is_client -eq 0 && $is_peer -eq 0 ]]; then
    die "Сущность '${name}' не найдена ни в CLIENTS (${CLIENTS[*]}), ни в AWG_PEERS (${AWG_PEERS[*]}). Добавьте её в config.env и запустите install.sh."
  fi

  # Имя может встречаться и там, и там — перевыпускаем обе ипостаси.
  [[ $is_client -eq 1 ]] && _regen_client "$name"
  [[ $is_peer   -eq 1 ]] && _regen_peer   "$name"

  log_ok "Готово: '${name}' перевыпущен, остальные ключи не тронуты."
}

main "$@"
