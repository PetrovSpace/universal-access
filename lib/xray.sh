#!/usr/bin/env bash
# lib/xray.sh — Xray-core (VLESS + Reality): три inbound'а на одном инстансе.
#   2053 — gRPC-режим (ОСНОВНОЙ: обходит детект почерка raw-TCP абонентским/моб. DPI РФ).
#   443  — blacklist-режим raw-TCP (план Б, нейтральный иностранный SNI).
#   8443 — whitelist-режим raw-TCP (план Б, разрешённый RU-ресурс для моб. RU/ТСПУ).
# gRPC использует те же UUID/ключи Reality, но БЕЗ flow (Vision несовместим с gRPC).
# Источается ПОСЛЕ lib/common.sh. Не переопределяет функции common.sh.
#
# ПЕРСИСТЕНТНОЕ СОСТОЯНИЕ (STATE_DIR, не удалять вручную — иначе клиентам нужны новые
# конфиги/ссылки): xray_reality_private, xray_reality_public, xray_uuid_<client>,
# xray_shortid_blacklist, xray_shortid_whitelist, xray_shortid_grpc,
# xray_sni_blacklist, xray_sni_whitelist.
set -euo pipefail

# Пути и константы Xray.
XRAY_BIN="${XRAY_BIN:-/usr/local/bin/xray}"
XRAY_CONFIG_DIR="${XRAY_CONFIG_DIR:-/usr/local/etc/xray}"
XRAY_CONFIG="${XRAY_CONFIG:-$XRAY_CONFIG_DIR/config.json}"
XRAY_INSTALL_URL="${XRAY_INSTALL_URL:-https://github.com/XTLS/Xray-install/raw/main/install-release.sh}"

# Генератор полноценных Happ-конфигов (gRPC + split-routing). Лежит в bin/ репо.
_XRAY_LIB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
GEN_CLIENT_PY="${GEN_CLIENT_PY:-${_XRAY_LIB_DIR}/../bin/gen-client-config.py}"

# ---------------------------------------------------------------------------
# Установка Xray-core через официальный скрипт (идемпотентно).
# ---------------------------------------------------------------------------
_xray_install_core() {
  if command -v "$XRAY_BIN" >/dev/null 2>&1 || [[ -x "$XRAY_BIN" ]]; then
    log_ok "Xray-core уже установлен: $("$XRAY_BIN" version 2>/dev/null | head -n1 || echo '?')"
    return 0
  fi
  ensure_packages curl ca-certificates unzip jq python3
  log_info "Установка Xray-core через официальный скрипт..."
  # @ install — ставит ядро + geodata, systemd-юнит xray.service, User=nobody.
  if ! bash -c "$(curl -fsSL "$XRAY_INSTALL_URL")" @ install >/dev/null 2>&1; then
    die "Не удалось установить Xray-core (install-release.sh)."
  fi
  [[ -x "$XRAY_BIN" ]] || die "Xray установлен, но бинарь $XRAY_BIN не найден."
  log_ok "Xray-core установлен: $("$XRAY_BIN" version 2>/dev/null | head -n1 || echo '?')"
}

# ---------------------------------------------------------------------------
# Reality keypair через state (приватный ключ — источник истины,
# публичный выводим из него детерминированно). Кладём в STATE_DIR.
# ---------------------------------------------------------------------------
_xray_x25519_field() {
  # Парсим вывод `xray x25519` устойчиво к разным версиям:
  #   старые:  "Private key: <...>" / "Public key: <...>"
  #   новые:   "PrivateKey: <...>"  / "Password (PublicKey): <...>"
  # $1 = private|public ; читаем вывод из stdin.
  local want="$1" line key val
  while IFS= read -r line; do
    # Нормализуем "ключ: значение".
    key="${line%%:*}"
    val="${line#*:}"
    # Убираем пробелы и приводим метку к нижнему регистру без пробелов.
    key="$(printf '%s' "$key" | tr 'A-Z' 'a-z' | tr -d ' ()')"
    val="$(printf '%s' "$val" | tr -d '[:space:]')"
    [[ -z "$val" ]] && continue
    case "$want:$key" in
      private:privatekey) printf '%s' "$val"; return 0 ;;
      # public: "password(publickey)" -> normalized "passwordpublickey"; "publickey"; "password".
      public:passwordpublickey) printf '%s' "$val"; return 0 ;;
      public:publickey)         printf '%s' "$val"; return 0 ;;
      public:password)          printf '%s' "$val"; return 0 ;;
    esac
  done
  return 1
}

_xray_gen_reality_private() {
  # Печатает приватный ключ Reality (x25519).
  local out priv
  out="$("$XRAY_BIN" x25519 2>/dev/null)" || return 1
  priv="$(printf '%s\n' "$out" | _xray_x25519_field private)" || return 1
  [[ -n "$priv" ]] || return 1
  printf '%s' "$priv"
}

_xray_pub_from_priv() {
  # Печатает публичный ключ Reality по приватному (xray x25519 -i <priv>).
  local priv="$1" out pub
  out="$("$XRAY_BIN" x25519 -i "$priv" 2>/dev/null)" || return 1
  pub="$(printf '%s\n' "$out" | _xray_x25519_field public)" || return 1
  [[ -n "$pub" ]] || return 1
  printf '%s' "$pub"
}

_xray_reality_keys() {
  # Гарантирует наличие приватного и публичного ключей Reality в state.
  # Заполняет глобалы REALITY_PRIV / REALITY_PUB.
  REALITY_PRIV="$(state_get_or_create xray_reality_private _xray_gen_reality_private)"
  [[ -n "$REALITY_PRIV" ]] || die "Не удалось получить приватный ключ Reality."
  # Публичный ключ детерминирован от приватного — всегда пересчитываем из него,
  # чтобы state не рассинхронизировался.
  if [[ -z "$(state_get xray_reality_public)" ]]; then
    local pub
    pub="$(_xray_pub_from_priv "$REALITY_PRIV")" \
      || die "Не удалось вычислить публичный ключ Reality из приватного."
    state_set xray_reality_public "$pub"
  fi
  REALITY_PUB="$(state_get xray_reality_public)"
  [[ -n "$REALITY_PUB" ]] || die "Пустой публичный ключ Reality."
}

_xray_short_id() {
  # shortId Reality — чётное число hex-символов (используем 8).
  gen_hex 8
}

# ---------------------------------------------------------------------------
# Валидация SNI: домен должен отдавать TLS 1.3 И HTTP/2.
# xray_validate_sni DOMAIN -> 0, если годен.
# ---------------------------------------------------------------------------
xray_validate_sni() {
  local domain="$1"
  [[ -n "$domain" ]] || return 1
  command -v openssl >/dev/null 2>&1 || ensure_packages openssl
  command -v curl >/dev/null 2>&1 || ensure_packages curl ca-certificates

  # 1) TLS 1.3: handshake к :443 с принудительным tls1_3.
  if ! printf 'Q\n' | timeout 10 openssl s_client -connect "${domain}:443" \
        -servername "$domain" -tls1_3 >/dev/null 2>&1; then
    log_warn "SNI '${domain}': нет TLS 1.3 — пропускаем."
    return 1
  fi

  # 2) HTTP/2: ALPN h2 должен согласоваться.
  local alpn
  alpn="$(printf 'Q\n' | timeout 10 openssl s_client -connect "${domain}:443" \
            -servername "$domain" -alpn h2 2>/dev/null \
          | grep -i 'ALPN protocol' || true)"
  if printf '%s' "$alpn" | grep -qi 'h2'; then
    log_ok "SNI '${domain}': TLS 1.3 + HTTP/2 — годен."
    return 0
  fi

  # Фолбэк-проверка HTTP/2 через curl (на случай особенностей вывода openssl).
  if curl -fsS --http2 --max-time 10 -o /dev/null -w '%{http_version}' \
        "https://${domain}/" 2>/dev/null | grep -q '^2'; then
    log_ok "SNI '${domain}': TLS 1.3 + HTTP/2 (curl) — годен."
    return 0
  fi

  log_warn "SNI '${domain}': нет HTTP/2 — пропускаем."
  return 1
}

_xray_pick_sni() {
  # Выбирает первый годный SNI из переданного списка кандидатов.
  # $@ = кандидаты. Печатает выбранный домен в stdout, годность -> код возврата.
  local cand
  for cand in "$@"; do
    [[ -n "$cand" ]] || continue
    if xray_validate_sni "$cand"; then
      printf '%s' "$cand"
      return 0
    fi
  done
  return 1
}

# ---------------------------------------------------------------------------
# Идемпотентный выбор SNI для режима.
#   $1 = state-ключ (xray_sni_blacklist|xray_sni_whitelist)
#   $2 = человекочитаемое имя режима (для логов)
#   $3.. = список кандидатов
# Печатает выбранный домен в stdout.
#
# ВАЖНО (идемпотентность): если в state УЖЕ сохранён SNI — доверяем ему без
# повторной сетевой проверки. xray_validate_sni делает живые openssl/curl-пробы;
# при кратковременном сбое сети (блип, временная недоступность цели, rate-limit)
# повторный прогон install/regen/update иначе отбросил бы сохранённый домен,
# подобрал бы ДРУГОЙ и переписал бы всем клиентам vless-ссылки на новый SNI —
# ломая уже импортированные конфиги из-за чисто транзиентного условия.
# Подбор по списку выполняется ТОЛЬКО когда в state пусто (первичная настройка).
# Намеренная смена SNI делается через set-sni.sh -> xray_apply_sni (там проверка
# домена выполняется явно).
# ---------------------------------------------------------------------------
_xray_resolve_sni() {
  local key="$1" mode="$2"; shift 2
  local saved
  saved="$(state_get "$key")"
  if [[ -n "$saved" ]]; then
    # Доверяем сохранённому значению — никаких сетевых проб на повторном прогоне.
    log_ok "${mode} SNI (из state, без повторной проверки): ${saved}"
    printf '%s' "$saved"
    return 0
  fi
  # state пуст — первичный подбор из кандидатов.
  local picked
  picked="$(_xray_pick_sni "$@")" || return 1
  state_set "$key" "$picked"
  log_ok "${mode} SNI (подобран и сохранён): ${picked}"
  printf '%s' "$picked"
}

# ---------------------------------------------------------------------------
# Per-client UUID (идемпотентно через state).
# ---------------------------------------------------------------------------
_xray_client_uuid() {
  # $1 = имя клиента ; печатает стабильный UUID.
  local client="$1"
  state_get_or_create "xray_uuid_${client}" gen_uuid
}

# ---------------------------------------------------------------------------
# Сборка config.json через jq: два Reality inbound'а + общий outbound.
# Глобалы на входе: REALITY_PRIV, SNI_BLACKLIST, SNI_WHITELIST,
#                   SID_BLACKLIST, SID_WHITELIST, CLIENTS[].
# ---------------------------------------------------------------------------
_xray_build_config() {
  local tmp clients_json clients_grpc_json client uuid
  # Суффикс .json ОБЯЗАТЕЛЕН: `xray run -test -config FILE` определяет формат
  # по расширению; без .json — «Failed to get format» и тест валится.
  tmp="$(mktemp --suffix=.json)" || tmp="$(mktemp)" || die "mktemp не сработал."
  case "$tmp" in *.json) ;; *) mv -f "$tmp" "$tmp.json" && tmp="$tmp.json" ;; esac

  # Два набора clients с ОДНИМИ И ТЕМИ ЖЕ UUID:
  #   clients_json      — для raw-TCP инбаундов (flow xtls-rprx-vision);
  #   clients_grpc_json — для gRPC инбаунда (flow ПУСТОЙ: Vision несовместим с gRPC).
  clients_json='[]'; clients_grpc_json='[]'
  for client in "${CLIENTS[@]}"; do
    uuid="$(_xray_client_uuid "$client")"
    [[ -n "$uuid" ]] || die "Пустой UUID для клиента '${client}'."
    clients_json="$(jq -c \
      --arg id "$uuid" \
      --arg email "$client" \
      '. + [{"id":$id,"flow":"xtls-rprx-vision","email":$email}]' \
      <<<"$clients_json")" || die "jq: не удалось добавить клиента '${client}'."
    clients_grpc_json="$(jq -c \
      --arg id "$uuid" \
      --arg email "${client}-grpc" \
      '. + [{"id":$id,"email":$email}]' \
      <<<"$clients_grpc_json")" || die "jq: не удалось добавить gRPC-клиента '${client}'."
  done

  # Полный конфиг. dest = serverName:443 (TLS-проксирование к реальному сайту).
  jq -n \
    --argjson clients "$clients_json" \
    --argjson clients_grpc "$clients_grpc_json" \
    --argjson port_bl "$REALITY_PORT_BLACKLIST" \
    --argjson port_wl "$REALITY_PORT_WHITELIST" \
    --argjson port_grpc "${REALITY_PORT_GRPC:-2053}" \
    --arg priv "$REALITY_PRIV" \
    --arg sni_bl "$SNI_BLACKLIST" \
    --arg sni_wl "$SNI_WHITELIST" \
    --arg sid_bl "$SID_BLACKLIST" \
    --arg sid_wl "$SID_WHITELIST" \
    --arg sid_grpc "$SID_GRPC" \
    --arg grpc_service "${GRPC_SERVICE_NAME:-grpc}" \
    '{
      "log": { "loglevel": "warning" },
      "inbounds": [
        {
          "tag": "vless-reality-grpc",
          "listen": "0.0.0.0",
          "port": $port_grpc,
          "protocol": "vless",
          "settings": {
            "clients": $clients_grpc,
            "decryption": "none"
          },
          "streamSettings": {
            "network": "grpc",
            "security": "reality",
            "realitySettings": {
              "show": false,
              "dest": ($sni_bl + ":443"),
              "xver": 0,
              "serverNames": [ $sni_bl ],
              "privateKey": $priv,
              "shortIds": [ "", $sid_grpc ]
            },
            "grpcSettings": {
              "serviceName": $grpc_service,
              "idle_timeout": 60,
              "health_check_timeout": 20,
              "permit_without_stream": true
            }
          },
          "sniffing": {
            "enabled": true,
            "destOverride": [ "http", "tls", "quic" ],
            "routeOnly": true
          }
        },
        {
          "tag": "vless-reality-blacklist",
          "listen": "0.0.0.0",
          "port": $port_bl,
          "protocol": "vless",
          "settings": {
            "clients": $clients,
            "decryption": "none"
          },
          "streamSettings": {
            "network": "tcp",
            "security": "reality",
            "realitySettings": {
              "show": false,
              "dest": ($sni_bl + ":443"),
              "xver": 0,
              "serverNames": [ $sni_bl ],
              "privateKey": $priv,
              "shortIds": [ "", $sid_bl ]
            }
          },
          "sniffing": {
            "enabled": true,
            "destOverride": [ "http", "tls", "quic" ],
            "routeOnly": true
          }
        },
        {
          "tag": "vless-reality-whitelist",
          "listen": "0.0.0.0",
          "port": $port_wl,
          "protocol": "vless",
          "settings": {
            "clients": $clients,
            "decryption": "none"
          },
          "streamSettings": {
            "network": "tcp",
            "security": "reality",
            "realitySettings": {
              "show": false,
              "dest": ($sni_wl + ":443"),
              "xver": 0,
              "serverNames": [ $sni_wl ],
              "privateKey": $priv,
              "shortIds": [ "", $sid_wl ]
            }
          },
          "sniffing": {
            "enabled": true,
            "destOverride": [ "http", "tls", "quic" ],
            "routeOnly": true
          }
        }
      ],
      "outbounds": [
        { "tag": "direct", "protocol": "freedom" },
        { "tag": "block", "protocol": "blackhole" }
      ]
    }' >"$tmp" || { rm -f "$tmp"; die "jq: не удалось собрать config.json."; }

  printf '%s' "$tmp"
}

# ---------------------------------------------------------------------------
# Запись vless:// ссылок для клиента (blacklist + whitelist).
# ---------------------------------------------------------------------------
_xray_url_encode() {
  # Минимальное URL-кодирование для query-значений (на всякий случай).
  local s="$1" out='' c i
  for ((i=0; i<${#s}; i++)); do
    c="${s:i:1}"
    case "$c" in
      [a-zA-Z0-9.~_-]) out+="$c" ;;
      *) out+="$(printf '%%%02X' "'$c")" ;;
    esac
  done
  printf '%s' "$out"
}

_xray_vless_link() {
  # _xray_vless_link UUID PORT SNI SHORTID PUBKEY LABEL
  local uuid="$1" port="$2" sni="$3" sid="$4" pub="$5" label="$6"
  local frag; frag="$(_xray_url_encode "$label")"
  printf 'vless://%s@%s:%s?encryption=none&flow=xtls-rprx-vision&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&spx=%%2F&type=tcp#%s\n' \
    "$uuid" "$PUBLIC_IP" "$port" "$sni" "$pub" "$sid" "$frag"
}

_xray_vless_link_grpc() {
  # _xray_vless_link_grpc UUID PORT SNI SHORTID PUBKEY SERVICE LABEL
  # gRPC: без flow (Vision несовместим), type=grpc, serviceName, mode=gun (одиночный поток).
  local uuid="$1" port="$2" sni="$3" sid="$4" pub="$5" svc="$6" label="$7"
  local frag svc_enc
  frag="$(_xray_url_encode "$label")"
  svc_enc="$(_xray_url_encode "$svc")"
  printf 'vless://%s@%s:%s?encryption=none&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&spx=%%2F&type=grpc&serviceName=%s&mode=gun#%s\n' \
    "$uuid" "$PUBLIC_IP" "$port" "$sni" "$pub" "$sid" "$svc_enc" "$frag"
}

_xray_emit_split_json() {
  # Best-effort: пишет vless-grpc-<client>.json (gRPC + split-routing RU-direct)
  # через bin/gen-client-config.py. Никогда не роняет установку (return 0), но при
  # НЕОЖИДАННОМ сбое (python сломан/ошибка генератора) — предупреждает в лог.
  local client="$1" uuid="$2" out="$CLIENTS_DIR/vless-grpc-${client}.json" err
  command -v python3 >/dev/null 2>&1 || return 0       # ожидаемо: нет python3 — молча
  [[ -f "$GEN_CLIENT_PY" ]] || return 0                # ожидаемо: нет генератора — молча
  # Требуемые глобалы должны быть заполнены вызывающим (xray_install/xray_apply_sni).
  if [[ -z "$SNI_BLACKLIST" || -z "$REALITY_PUB" || -z "$SID_GRPC" ]]; then
    log_warn "Split-routing JSON пропущен: пусто SNI_BLACKLIST/REALITY_PUB/SID_GRPC."
    return 0
  fi
  [[ -d "$CLIENTS_DIR" ]] || { log_warn "Split-routing JSON пропущен: нет ${CLIENTS_DIR}."; return 0; }
  if err="$(python3 "$GEN_CLIENT_PY" --id "$uuid" --host "$PUBLIC_IP" \
       --port "${REALITY_PORT_GRPC:-2053}" --sni "$SNI_BLACKLIST" --pbk "$REALITY_PUB" \
       --sid "$SID_GRPC" --net grpc --flow "" --fp chrome \
       --grpc-service "${GRPC_SERVICE_NAME:-grpc}" \
       --remark "RU gRPC ${client}" --out "$out" 2>&1)"; then
    chmod 0600 "$out" 2>/dev/null || true
    log_ok "Split-routing конфиг: ${out}"
  else
    log_warn "Split-routing JSON не создан (python): ${err}"
  fi
  return 0
}

_xray_write_client_files() {
  # ОСНОВНОЙ путь — gRPC (vless-grpc-<c>.txt + .json со split-routing).
  # ПЛАН Б — raw-TCP blacklist :443 и whitelist :8443 (vless-reality/whitelist-<c>.txt).
  local client uuid f_grpc f_bl f_wl
  for client in "${CLIENTS[@]}"; do
    uuid="$(_xray_client_uuid "$client")"
    f_grpc="$CLIENTS_DIR/vless-grpc-${client}.txt"
    f_bl="$CLIENTS_DIR/vless-reality-${client}.txt"
    f_wl="$CLIENTS_DIR/vless-whitelist-${client}.txt"

    {
      printf '# VLESS + Reality gRPC (порт %s) — клиент: %s\n' "${REALITY_PORT_GRPC:-2053}" "$client"
      printf '# ОСНОВНОЙ путь: gRPC обходит детект почерка raw-TCP абонентским/мобильным DPI РФ.\n'
      printf '# Приложение Happ: импортируй .json (vless-grpc-%s.json) для split-routing, или ссылку ниже.\n' "$client"
      printf '# SNI: %s ; serviceName: %s\n\n' "$SNI_BLACKLIST" "${GRPC_SERVICE_NAME:-grpc}"
      _xray_vless_link_grpc "$uuid" "${REALITY_PORT_GRPC:-2053}" "$SNI_BLACKLIST" \
        "$SID_GRPC" "$REALITY_PUB" "${GRPC_SERVICE_NAME:-grpc}" "grpc-${client}"
    } >"$f_grpc" || die "Не удалось записать ${f_grpc}."
    chmod 0600 "$f_grpc" || true

    # Полный конфиг со split-routing (best-effort, если есть python3+генератор).
    _xray_emit_split_json "$client" "$uuid"

    {
      printf '# [ПЛАН Б] VLESS + Reality raw-TCP (blacklist, %s) — клиент: %s\n' "$REALITY_PORT_BLACKLIST" "$client"
      printf '# Резерв, если gRPC перестанет работать. На жёстком DPI РФ raw-TCP часто режется.\n'
      printf '# SNI: %s\n\n' "$SNI_BLACKLIST"
      _xray_vless_link "$uuid" "$REALITY_PORT_BLACKLIST" "$SNI_BLACKLIST" \
        "$SID_BLACKLIST" "$REALITY_PUB" "reality-${client}"
    } >"$f_bl" || die "Не удалось записать ${f_bl}."
    chmod 0600 "$f_bl" || true

    {
      printf '# [ПЛАН Б] VLESS + Reality raw-TCP (whitelist, %s) — клиент: %s\n' "$REALITY_PORT_WHITELIST" "$client"
      printf '# Резерв для мобильных RU/ТСПУ (разрешённый RU-SNI).\n'
      printf '# SNI (разрешённый RU-ресурс): %s\n\n' "$SNI_WHITELIST"
      _xray_vless_link "$uuid" "$REALITY_PORT_WHITELIST" "$SNI_WHITELIST" \
        "$SID_WHITELIST" "$REALITY_PUB" "whitelist-${client}"
    } >"$f_wl" || die "Не удалось записать ${f_wl}."
    chmod 0600 "$f_wl" || true

    log_ok "Клиент '${client}': ОСНОВНОЙ ${f_grpc} (+.json), план Б ${f_bl}, ${f_wl}"
  done
}

# ---------------------------------------------------------------------------
# Тест конфигурации и (пере)запуск сервиса.
# ---------------------------------------------------------------------------
_xray_test_and_apply() {
  # $1 = путь к новому config.json (tmp). При успехе теста — заменяет рабочий.
  local newcfg="$1"
  [[ -s "$newcfg" ]] || die "Сгенерирован пустой config.json."
  mkdir -p "$XRAY_CONFIG_DIR" || die "Не удалось создать ${XRAY_CONFIG_DIR}."

  if ! "$XRAY_BIN" run -test -config "$newcfg" >/dev/null 2>&1; then
    log_error "xray run -test провалился. Вывод:"
    "$XRAY_BIN" run -test -config "$newcfg" 2>&1 | sed 's/^/    /' >&2 || true
    rm -f "$newcfg"
    die "Невалидная конфигурация Xray — рабочий config.json не тронут."
  fi

  # Бэкап текущего и атомарная подмена.
  if [[ -f "$XRAY_CONFIG" ]]; then
    cp -a "$XRAY_CONFIG" "${XRAY_CONFIG}.bak" 2>/dev/null || true
  fi
  install -m 0644 "$newcfg" "$XRAY_CONFIG" || { rm -f "$newcfg"; die "Не удалось установить ${XRAY_CONFIG}."; }
  rm -f "$newcfg"

  systemctl enable xray >/dev/null 2>&1 || true
  if ! systemctl restart xray >/dev/null 2>&1; then
    log_error "Не удалось перезапустить xray. Журнал:"
    journalctl -u xray -n 20 --no-pager 2>/dev/null | sed 's/^/    /' >&2 || true
    die "Сервис xray не запустился."
  fi
  systemctl is-active --quiet xray || die "xray не активен после перезапуска."
  log_ok "Xray запущен (config: ${XRAY_CONFIG})."
}

# ---------------------------------------------------------------------------
# Публичная: полная установка/обновление Xray по контракту.
# ---------------------------------------------------------------------------
xray_install() {
  log_step "Xray (VLESS + Reality): установка и настройка"
  require_root
  state_init
  _xray_install_core

  # Ключи Reality.
  _xray_reality_keys

  # shortId на каждый inbound (стабильные, через state).
  SID_BLACKLIST="$(state_get_or_create xray_shortid_blacklist _xray_short_id)"
  SID_WHITELIST="$(state_get_or_create xray_shortid_whitelist _xray_short_id)"
  SID_GRPC="$(state_get_or_create xray_shortid_grpc _xray_short_id)"
  [[ -n "$SID_BLACKLIST" && -n "$SID_WHITELIST" && -n "$SID_GRPC" ]] || die "Не удалось получить shortId."

  # Выбор SNI (идемпотентно): сохранённое в state значение используется КАК ЕСТЬ,
  # без повторной сетевой проверки — иначе транзиентный сбой пробы ротировал бы SNI
  # и переписал клиентам уже импортированные ссылки. Подбор по списку — только при
  # пустом state. Намеренная смена — через set-sni.sh (xray_apply_sni).
  SNI_BLACKLIST="$(_xray_resolve_sni xray_sni_blacklist "Blacklist" "${REALITY_SNI_BLACKLIST[@]}")" \
    || die "Ни один blacklist-SNI не прошёл проверку TLS1.3+HTTP2. Проверьте REALITY_SNI_BLACKLIST."

  SNI_WHITELIST="$(_xray_resolve_sni xray_sni_whitelist "Whitelist" "${REALITY_SNI_WHITELIST[@]}")" \
    || die "Ни один whitelist-SNI (RU) не прошёл проверку. Проверьте REALITY_SNI_WHITELIST."

  # Сборка, тест, применение.
  local cfg; cfg="$(_xray_build_config)"
  _xray_test_and_apply "$cfg"

  # Клиентские файлы со ссылками.
  _xray_write_client_files

  log_ok "Xray готов: gRPC :${REALITY_PORT_GRPC:-2053} (основной), blacklist :${REALITY_PORT_BLACKLIST}, whitelist :${REALITY_PORT_WHITELIST} (план Б)."
}

# ---------------------------------------------------------------------------
# Публичная: смена SNI для одного режима и перезапуск.
# xray_apply_sni MODE DOMAIN ; MODE = blacklist|whitelist.
# ---------------------------------------------------------------------------
xray_apply_sni() {
  local mode="$1" domain="$2"
  [[ -n "$mode" && -n "$domain" ]] || die "xray_apply_sni: нужны MODE и DOMAIN."
  case "$mode" in
    blacklist|whitelist) ;;
    *) die "xray_apply_sni: MODE должен быть blacklist|whitelist (получено '${mode}')." ;;
  esac
  require_root
  state_init
  command -v "$XRAY_BIN" >/dev/null 2>&1 || [[ -x "$XRAY_BIN" ]] \
    || die "Xray не установлен — сначала запустите install.sh."

  # Намеренная смена SNI: домен проверяем явно (в отличие от idempotent-прогона).
  if ! xray_validate_sni "$domain"; then
    die "Домен '${domain}' не годится (нужны TLS 1.3 + HTTP/2)."
  fi

  # Подтягиваем ключи и текущие значения второго режима из state.
  _xray_reality_keys
  SID_BLACKLIST="$(state_get_or_create xray_shortid_blacklist _xray_short_id)"
  SID_WHITELIST="$(state_get_or_create xray_shortid_whitelist _xray_short_id)"
  SID_GRPC="$(state_get_or_create xray_shortid_grpc _xray_short_id)"

  if [[ "$mode" == "blacklist" ]]; then
    SNI_BLACKLIST="$domain"; state_set xray_sni_blacklist "$domain"
    SNI_WHITELIST="$(state_get xray_sni_whitelist)"
    [[ -n "$SNI_WHITELIST" ]] || die "Не задан whitelist-SNI в state — запустите install.sh."
  else
    SNI_WHITELIST="$domain"; state_set xray_sni_whitelist "$domain"
    SNI_BLACKLIST="$(state_get xray_sni_blacklist)"
    [[ -n "$SNI_BLACKLIST" ]] || die "Не задан blacklist-SNI в state — запустите install.sh."
  fi

  local cfg; cfg="$(_xray_build_config)"
  _xray_test_and_apply "$cfg"
  _xray_write_client_files
  log_ok "SNI режима '${mode}' изменён на '${domain}'."
}
