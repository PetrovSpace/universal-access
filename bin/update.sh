#!/usr/bin/env bash
# bin/update.sh — обновляет Xray-core и AmneziaWG до последних версий, перезапускает
# сервисы, СОХРАНЯЯ существующие конфиги, ключи и клиентские файлы.
# Идемпотентно и неинтерактивно. Использует только функции common.sh/модулей.
set -euo pipefail

# --- Резолвинг корня репозитория относительно этого скрипта ------------------
# REPO_ROOT = dir-of-bin/.. (bin/* лежат внутри репозитория).
_SELF="${BASH_SOURCE[0]}"
while [[ -L "$_SELF" ]]; do
  _LINK="$(readlink "$_SELF")"
  case "$_LINK" in
    /*) _SELF="$_LINK" ;;
    *)  _SELF="$(dirname "$_SELF")/$_LINK" ;;
  esac
done
BIN_DIR="$(cd "$(dirname "$_SELF")" && pwd)"
REPO_ROOT="$(cd "$BIN_DIR/.." && pwd)"

# Пути модулей (до load_config, чтобы SRC_DIR указывал на репозиторий).
SRC_DIR="${SRC_DIR:-$REPO_ROOT}"
export SRC_DIR

# shellcheck source=/dev/null
. "$REPO_ROOT/lib/common.sh" || { echo "Не найден lib/common.sh рядом со скриптом." >&2; exit 1; }
# shellcheck source=/dev/null
. "$REPO_ROOT/lib/amneziawg.sh" || die "Не найден lib/amneziawg.sh."
# shellcheck source=/dev/null
. "$REPO_ROOT/lib/xray.sh" || die "Не найден lib/xray.sh."

# --- Подготовка окружения ----------------------------------------------------
load_config
require_root
detect_os
detect_default_iface
state_init

# Публичный IP нужен для возможной перегенерации серверного конфига AmneziaWG.
detect_public_ip

# ---------------------------------------------------------------------------
# Обновление Xray-core до последней версии (официальный install-release.sh).
# Конфиг (config.json), ключи Reality и клиентские ссылки НЕ трогаем.
# ---------------------------------------------------------------------------
_update_xray() {
  log_step "Обновление Xray-core до последней версии"

  if ! command -v "$XRAY_BIN" >/dev/null 2>&1 && [[ ! -x "$XRAY_BIN" ]]; then
    log_warn "Xray не установлен — пропускаю обновление (запустите install.sh)."
    return 0
  fi

  local before after
  before="$("$XRAY_BIN" version 2>/dev/null | head -n1 || echo '?')"
  log_info "Текущая версия Xray: ${before}"

  ensure_packages curl ca-certificates unzip jq
  # Официальный режим обновления ядра без переустановки конфигов/юнита.
  if ! bash -c "$(curl -fsSL "$XRAY_INSTALL_URL")" @ install >/dev/null 2>&1; then
    log_warn "Не удалось обновить Xray-core (install-release.sh). Версия остаётся прежней."
    return 0
  fi
  [[ -x "$XRAY_BIN" ]] || die "После обновления бинарь Xray ($XRAY_BIN) не найден."

  after="$("$XRAY_BIN" version 2>/dev/null | head -n1 || echo '?')"
  log_ok "Xray обновлён: было «${before}», стало «${after}»."

  # Проверяем существующий конфиг новым бинарём перед перезапуском.
  if [[ -f "$XRAY_CONFIG" ]]; then
    if ! "$XRAY_BIN" run -test -config "$XRAY_CONFIG" >/dev/null 2>&1; then
      log_error "Существующий config.json не прошёл проверку новой версией Xray:"
      "$XRAY_BIN" run -test -config "$XRAY_CONFIG" 2>&1 | sed 's/^/    /' >&2 || true
      die "Обновлённый Xray несовместим с текущим config.json — сервис НЕ перезапущен."
    fi
  else
    log_warn "Файл ${XRAY_CONFIG} отсутствует — пропускаю перезапуск Xray."
    return 0
  fi

  systemctl enable xray >/dev/null 2>&1 || true
  if ! systemctl restart xray >/dev/null 2>&1; then
    log_error "Не удалось перезапустить xray после обновления. Журнал:"
    journalctl -u xray -n 20 --no-pager 2>/dev/null | sed 's/^/    /' >&2 || true
    die "Сервис xray не запустился после обновления."
  fi
  systemctl is-active --quiet xray || die "xray не активен после перезапуска."
  log_ok "Xray перезапущен на обновлённой версии (config сохранён)."
}

# ---------------------------------------------------------------------------
# Обновление AmneziaWG до последней версии.
#   - Ядерный путь (DKMS): apt-обновление пакетов amneziawg-* + пересборка DKMS.
#   - Userspace-путь (amneziawg-go): git pull + пересборка бинаря.
# Серверный/клиентские конфиги и ключи (state) сохраняются. Перезапускаем awg0.
# ---------------------------------------------------------------------------
_update_amneziawg() {
  log_step "Обновление AmneziaWG до последней версии"

  if ! command -v awg-quick >/dev/null 2>&1; then
    log_warn "AmneziaWG не установлен — пропускаю обновление (запустите install.sh)."
    return 0
  fi

  local updated=0

  # Путь 1: пакеты из репо (Ubuntu/PPA). Обновляем amneziawg-tools/-dkms, если стоят.
  local pkg pkgs=()
  for pkg in amneziawg-tools amneziawg-dkms; do
    if dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q 'install ok installed'; then
      pkgs+=("$pkg")
    fi
  done
  if [[ ${#pkgs[@]} -gt 0 ]]; then
    log_info "Обновление пакетов AmneziaWG: ${pkgs[*]}"
    apt_update_once
    if DEBIAN_FRONTEND=noninteractive apt-get install -y --only-upgrade "${pkgs[@]}" >/dev/null 2>&1; then
      log_ok "Пакеты AmneziaWG обновлены: ${pkgs[*]}."
      updated=1
    else
      log_warn "Не удалось обновить часть пакетов AmneziaWG — продолжаю."
    fi
    # Пересборка ядерного модуля под текущее ядро (если используется DKMS).
    if command -v dkms >/dev/null 2>&1; then
      dkms autoinstall >/dev/null 2>&1 || true
    fi
  fi

  # Путь 2: userspace amneziawg-go — обновляем из git и пересобираем.
  if command -v amneziawg-go >/dev/null 2>&1; then
    local build_dir="${SRC_DIR}/amneziawg-go"
    if [[ -d "${build_dir}/.git" ]]; then
      log_info "Обновление amneziawg-go из git..."
      ensure_packages git make golang-go
      if git -C "${build_dir}" pull --ff-only >/dev/null 2>&1; then
        if make -C "${build_dir}" >/dev/null 2>&1; then
          make -C "${build_dir}" install >/dev/null 2>&1 \
            || install -v -m 0755 "${build_dir}/amneziawg-go" /usr/bin/amneziawg-go >/dev/null 2>&1 \
            || log_warn "Не удалось установить пересобранный amneziawg-go."
          log_ok "amneziawg-go пересобран: $(command -v amneziawg-go)."
          updated=1
        else
          log_warn "Сборка amneziawg-go не удалась — оставляю прежний бинарь."
        fi
      else
        log_warn "git pull amneziawg-go не удался — оставляю текущую версию."
      fi
    else
      log_info "Каталог сборки amneziawg-go не найден — обновление userspace пропущено."
    fi
  fi

  [[ $updated -eq 1 ]] || log_warn "Не нашёл, что обновлять в AmneziaWG (нет пакетов/исходников)."

  # Перезапуск интерфейса для подхвата новой версии. Конфиг awg0.conf не трогаем.
  if [[ -f "${AWG_CONF}" ]]; then
    if systemctl is-active --quiet "awg-quick@${AWG_IFACE}"; then
      if systemctl restart "awg-quick@${AWG_IFACE}" >/dev/null 2>&1; then
        log_ok "Интерфейс ${AWG_IFACE} перезапущен на обновлённой версии."
      else
        log_error "Не удалось перезапустить awg-quick@${AWG_IFACE}. Журнал:"
        journalctl -u "awg-quick@${AWG_IFACE}" -n 20 --no-pager 2>/dev/null | sed 's/^/    /' >&2 || true
        die "Сервис awg-quick@${AWG_IFACE} не запустился после обновления."
      fi
    else
      log_warn "Сервис awg-quick@${AWG_IFACE} не запущен — пропускаю перезапуск."
    fi
  else
    log_warn "Конфиг ${AWG_CONF} отсутствует — пропускаю перезапуск AmneziaWG."
  fi
}

# --- Точка входа -------------------------------------------------------------
main() {
  log_step "Обновление компонентов access server (конфиги сохраняются)"
  _update_xray
  _update_amneziawg
  log_ok "Обновление завершено. Ключи, конфиги и клиентские файлы не изменены."
}

main "$@"
