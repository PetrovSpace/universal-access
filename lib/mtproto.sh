#!/usr/bin/env bash
# lib/mtproto.sh — MTProto-прокси для Telegram через mtg v2 (fake-TLS).
# Источается после common.sh. Определяет mtproto_install (см. контракт).
# Не переопределяет функции common.sh — только использует их.
set -euo pipefail

# Версия mtg по умолчанию (можно переопределить через config.env: MTG_VERSION).
: "${MTG_VERSION:=2.2.8}"

MTG_BIN="${MTG_BIN:-/usr/local/bin/mtg}"
MTG_CONF_DIR="${MTG_CONF_DIR:-/etc/mtg}"
MTG_CONF="${MTG_CONF:-$MTG_CONF_DIR/config.toml}"
MTG_SERVICE=mtg
MTG_UNIT="${MTG_UNIT:-/etc/systemd/system/${MTG_SERVICE}.service}"
MTG_USER=mtg

# --- Архитектура GitHub-релиза для текущего ядра -----------------------------
_mtg_release_arch() {
  local m; m=$(uname -m)
  case "$m" in
    x86_64|amd64)        printf 'amd64\n' ;;
    aarch64|arm64)       printf 'arm64\n' ;;
    armv7l|armv7|armhf)  printf 'armv7\n' ;;
    armv6l|armv6)        printf 'armv6\n' ;;
    i386|i686)           printf '386\n' ;;
    *) die "mtg: неподдерживаемая архитектура '$m'." ;;
  esac
}

# --- Установка бинарника mtg нужной версии/архитектуры -----------------------
_mtg_install_binary() {
  # Идемпотентно: если уже стоит нужная версия — выходим.
  if [[ -x "$MTG_BIN" ]]; then
    local have
    have=$("$MTG_BIN" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || true)
    if [[ "$have" == "$MTG_VERSION" ]]; then
      log_ok "mtg ${MTG_VERSION} уже установлен."
      return 0
    fi
  fi

  ensure_packages curl ca-certificates tar
  local arch tarball url tmp
  arch=$(_mtg_release_arch)
  tarball="mtg-${MTG_VERSION}-linux-${arch}.tar.gz"
  url="https://github.com/9seconds/mtg/releases/download/v${MTG_VERSION}/${tarball}"

  tmp=$(mktemp -d) || die "mtg: не удалось создать временный каталог."
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp'" RETURN

  log_info "Скачивание mtg ${MTG_VERSION} (${arch})..."
  curl -fsSL --retry 3 --max-time 120 -o "$tmp/$tarball" "$url" \
    || die "mtg: не удалось скачать релиз: $url"

  tar -xzf "$tmp/$tarball" -C "$tmp" \
    || die "mtg: не удалось распаковать архив."

  # Бинарник лежит внутри распакованного каталога; найдём его.
  local found
  found=$(find "$tmp" -type f -name mtg -perm -u+x 2>/dev/null | head -n1 || true)
  [[ -z "$found" ]] && found=$(find "$tmp" -type f -name mtg 2>/dev/null | head -n1 || true)
  [[ -n "$found" ]] || die "mtg: бинарник 'mtg' не найден в архиве."

  install -m 0755 "$found" "$MTG_BIN" || die "mtg: не удалось установить бинарник в ${MTG_BIN}."
  log_ok "mtg установлен: ${MTG_BIN} ($("$MTG_BIN" --version 2>/dev/null | head -n1 || echo "$MTG_VERSION"))."
}

# --- Системный пользователь под сервис ---------------------------------------
_mtg_ensure_user() {
  if ! id -u "$MTG_USER" >/dev/null 2>&1; then
    useradd --system --no-create-home --shell /usr/sbin/nologin "$MTG_USER" 2>/dev/null \
      || useradd --system --no-create-home --shell /bin/false "$MTG_USER" 2>/dev/null \
      || die "mtg: не удалось создать системного пользователя ${MTG_USER}."
    log_ok "Создан системный пользователь ${MTG_USER}."
  fi
}

# --- Hex-домена маскировки для tg:///t.me ссылок -----------------------------
_mtg_domain_hex() {
  # FakeTLS: к секрету добавляется hex(домен). printf домена в hex.
  printf '%s' "$1" | od -An -tx1 | tr -d ' \n'
}

# --- Сборка ee-секрета вручную (детерминированно, без вызова mtg) ------------
_mtg_make_secret() {
  # FakeTLS-секрет: "ee" + 32 hex (16 случайных байт) + hex(MASK_DOMAIN).
  local domain="$1" rand dhex
  rand=$(gen_hex 32) || die "mtg: не удалось сгенерировать случайную часть секрета."
  dhex=$(_mtg_domain_hex "$domain")
  printf 'ee%s%s' "$rand" "$dhex"
}

# --- Systemd-юнит ------------------------------------------------------------
_mtg_write_unit() {
  cat >"$MTG_UNIT" <<EOF
[Unit]
Description=mtg — MTProto proxy (fake-TLS)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${MTG_USER}
ExecStart=${MTG_BIN} run ${MTG_CONF}
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576
AmbientCapabilities=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
ReadOnlyPaths=${MTG_CONF_DIR}

[Install]
WantedBy=multi-user.target
EOF
  log_ok "Записан systemd-юнит: ${MTG_UNIT}"
}

# --- Файл config.toml --------------------------------------------------------
_mtg_write_config() {
  # mtg v2 поддерживает РОВНО ОДИН секрет на инстанс — это общий секрет всех клиентов.
  local secret="$1"
  install -d -m 0750 -o "$MTG_USER" -g "$MTG_USER" "$MTG_CONF_DIR" 2>/dev/null \
    || install -d -m 0750 "$MTG_CONF_DIR" \
    || die "mtg: не удалось создать ${MTG_CONF_DIR}."

  cat >"$MTG_CONF" <<EOF
# mtg config — fake-TLS под ${MTPROTO_MASK_DOMAIN}. Управляется install.sh.
secret = "${secret}"
bind-to = "0.0.0.0:${MTPROTO_PORT}"
concurrency = 8192
EOF
  chmod 0640 "$MTG_CONF" || true
  chown "$MTG_USER":"$MTG_USER" "$MTG_CONF" 2>/dev/null || true
  log_ok "Записан конфиг mtg: ${MTG_CONF}"
}

# --- Клиентский артефакт telegram-proxy-<client>.txt -------------------------
_mtg_write_client_file() {
  local client="$1" secret="$2"
  local out="$CLIENTS_DIR/telegram-proxy-${client}.txt"
  local tg_link tme_link
  tg_link="tg://proxy?server=${PUBLIC_IP}&port=${MTPROTO_PORT}&secret=${secret}"
  tme_link="https://t.me/proxy?server=${PUBLIC_IP}&port=${MTPROTO_PORT}&secret=${secret}"

  cat >"$out" <<EOF
# Telegram MTProto-прокси (fake-TLS) — клиент: ${client}
# Маскировка под: ${MTPROTO_MASK_DOMAIN}
# Сервер: ${PUBLIC_IP}:${MTPROTO_PORT}
#
# Открыть в Telegram (нажмите ссылку):
${tme_link}
#
# Прямая ссылка для приложения:
${tg_link}
EOF
  chmod 0600 "$out" || true
  log_ok "Клиент ${client}: ${out}"
}

# --- Главная функция (контракт) ----------------------------------------------
mtproto_install() {
  log_step "MTProto (Telegram) — mtg v2, fake-TLS"

  # Порт: идемпотентность. Сначала восстанавливаем ранее выбранный порт из
  # состояния, чтобы уже выданные tg://-ссылки оставались валидными. Авто-
  # повышение запускаем только если порт ещё не сохранён или сохранённый порт
  # действительно занят чужим процессом.
  local saved_port
  saved_port=$(state_get mtproto_port)
  if [[ -n "$saved_port" ]]; then
    MTPROTO_PORT="$saved_port"
    export MTPROTO_PORT
    if ! is_port_free "$MTPROTO_PORT" tcp; then
      # Порт занят: возможно, это наш же уже запущенный сервис mtg — тогда
      # порт остаётся за нами. Иначе (чужой процесс) переезжаем на свободный.
      if systemctl is-active --quiet "$MTG_SERVICE" 2>/dev/null; then
        log_info "MTPROTO_PORT ${MTPROTO_PORT} занят собственным сервисом mtg — оставляю как есть."
      else
        local newport
        newport=$(find_free_port "$MTPROTO_PORT" tcp)
        log_warn "Сохранённый MTPROTO_PORT ${MTPROTO_PORT} занят чужим процессом — переключаюсь на ${newport}."
        MTPROTO_PORT="$newport"
        export MTPROTO_PORT
      fi
    else
      log_info "MTPROTO_PORT восстановлен из состояния: ${MTPROTO_PORT}."
    fi
  else
    # Первый запуск: порт из конфига, авто-повышение при занятости.
    if ! is_port_free "$MTPROTO_PORT" tcp; then
      local newport
      newport=$(find_free_port "$MTPROTO_PORT" tcp)
      log_warn "MTPROTO_PORT ${MTPROTO_PORT} занят — переключаюсь на ${newport}."
      MTPROTO_PORT="$newport"
      export MTPROTO_PORT
    fi
  fi
  # Запоминаем выбранный порт в состоянии (для info/firewall согласованности).
  state_set mtproto_port "$MTPROTO_PORT"

  _mtg_install_binary
  _mtg_ensure_user

  # ВАЖНО: mtg v2 поддерживает РОВНО ОДИН секрет на инстанс. Поэтому секрет —
  # ОБЩИЙ для всех клиентов (иначе работал бы только первый). Храним один секрет
  # в state-ключе mtproto_secret (идемпотентно).
  local secret
  secret=$(state_get_or_create mtproto_secret _mtg_make_secret "$MTPROTO_MASK_DOMAIN")
  # Если домен маскировки сменился — hex-хвост секрета устарел, перевыпускаем.
  local want_tail cur_tail
  want_tail=$(_mtg_domain_hex "$MTPROTO_MASK_DOMAIN")
  cur_tail="${secret#ee}"; cur_tail="${cur_tail:32}"
  if [[ "$cur_tail" != "$want_tail" ]]; then
    log_warn "Домен маскировки изменился — перевыпускаю общий MTProto-секрет."
    secret=$(_mtg_make_secret "$MTPROTO_MASK_DOMAIN")
    state_set mtproto_secret "$secret"
  fi

  # Клиентские файлы: один и тот же рабочий секрет каждому (имена сохраняем для
  # удобства; фактически Telegram-прокси общий для всех клиентов).
  local client have_client=0
  for client in "${CLIENTS[@]}"; do
    [[ -n "$client" ]] || continue
    have_client=1
    _mtg_write_client_file "$client" "$secret"
  done
  [[ $have_client -eq 1 ]] || log_warn "mtg: список CLIENTS пуст — секрет создан, но клиентских файлов нет."

  _mtg_write_config "$secret"
  _mtg_write_unit

  systemctl daemon-reload || die "mtg: не удалось перезагрузить systemd."
  systemctl enable "$MTG_SERVICE" >/dev/null 2>&1 || log_warn "mtg: не удалось включить автозапуск."
  systemctl restart "$MTG_SERVICE" || die "mtg: не удалось запустить сервис ${MTG_SERVICE}."

  # Проверка, что сервис действительно поднялся.
  sleep 1
  if ! systemctl is-active --quiet "$MTG_SERVICE"; then
    log_error "mtg: сервис не активен. Журнал:"
    journalctl -u "$MTG_SERVICE" -n 20 --no-pager >&2 2>/dev/null || true
    die "mtg: запуск завершился неудачей."
  fi

  log_ok "MTProto-прокси работает на ${PUBLIC_IP}:${MTPROTO_PORT} (маскировка под ${MTPROTO_MASK_DOMAIN})."
}
