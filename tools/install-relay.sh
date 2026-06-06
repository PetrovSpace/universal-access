#!/usr/bin/env bash
# install-relay.sh — постоянный ПЛАН Б: РФ-релей на промежуточном сервере.
# Цепочка: устройство --gRPC--> релей:$RELAY_PORT --gRPC--> зарубеж $FOREIGN_IP:$FOREIGN_PORT --> интернет.
# Вход на РФ-IP (дружелюбно к мобильному whitelist), выход за рубежом (обходит блок).
#
# Секреты НЕ хардкодятся — берутся из окружения (см. tools/relay.env.example).
# Реальные значения держи в local/relay.env (он в .gitignore) и запускай так:
#   cat local/relay.env universal-access/tools/install-relay.sh | ssh ru 'bash -s'
set -euo pipefail

# --- Параметры (обязательные — из relay.env) ---
: "${FOREIGN_IP:?Не задан FOREIGN_IP (см. relay.env)}"
: "${FOREIGN_PORT:=2053}"
: "${FOREIGN_UUID:?Не задан FOREIGN_UUID}"
: "${FOREIGN_PUBKEY:?Не задан FOREIGN_PUBKEY}"
: "${FOREIGN_SHORTID:?Не задан FOREIGN_SHORTID}"
: "${RELAY_PORT:=443}"
: "${RELAY_UUID:?Не задан RELAY_UUID}"
: "${RELAY_PRIVKEY:?Не задан RELAY_PRIVKEY}"
: "${RELAY_SHORTID:?Не задан RELAY_SHORTID}"
: "${SNI:=www.microsoft.com}"
: "${GRPC_SERVICE:=grpc}"

BIN=/usr/local/bin/xray
CFGDIR=/usr/local/etc/xray-relay
CFG="$CFGDIR/config.json"
UNIT=/etc/systemd/system/xray-relay.service

# 1) xray-бинарь (берём уже скачанный в /root/xtest, иначе тянем релиз)
if [ ! -x "$BIN" ]; then
  if [ -x /root/xtest/xray ]; then install -m755 /root/xtest/xray "$BIN"
  else
    command -v unzip >/dev/null 2>&1 || { apt-get update -qq && apt-get install -y -qq unzip; }
    tmp=$(mktemp -d); curl -fsSL -o "$tmp/x.zip" \
      https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip
    unzip -q "$tmp/x.zip" -d "$tmp"; install -m755 "$tmp/xray" "$BIN"; rm -rf "$tmp"
  fi
fi

# 2) конфиг релея (значения подставляются из окружения)
mkdir -p "$CFGDIR"
cat > "$CFG" <<JSON
{
  "log": {"loglevel":"warning"},
  "inbounds": [{
    "tag":"in-grpc","listen":"0.0.0.0","port":${RELAY_PORT},"protocol":"vless",
    "settings":{"clients":[{"id":"${RELAY_UUID}","email":"relay"}],"decryption":"none"},
    "streamSettings":{"network":"grpc","security":"reality","realitySettings":{
       "show":false,"dest":"${SNI}:443","xver":0,
       "serverNames":["${SNI}"],
       "privateKey":"${RELAY_PRIVKEY}","shortIds":["","${RELAY_SHORTID}"]},
       "grpcSettings":{"serviceName":"${GRPC_SERVICE}"}},
    "sniffing":{"enabled":true,"destOverride":["http","tls","quic"],"routeOnly":true}
  }],
  "outbounds": [
    {"tag":"to-foreign","protocol":"vless",
     "settings":{"vnext":[{"address":"${FOREIGN_IP}","port":${FOREIGN_PORT},"users":[{"id":"${FOREIGN_UUID}","encryption":"none"}]}]},
     "streamSettings":{"network":"grpc","security":"reality","realitySettings":{
        "serverName":"${SNI}","fingerprint":"chrome","publicKey":"${FOREIGN_PUBKEY}","shortId":"${FOREIGN_SHORTID}"},
        "grpcSettings":{"serviceName":"${GRPC_SERVICE}"}}},
    {"tag":"direct","protocol":"freedom"},
    {"tag":"block","protocol":"blackhole"}
  ],
  "routing":{"rules":[{"type":"field","network":"tcp,udp","outboundTag":"to-foreign"}]}
}
JSON

"$BIN" run -test -config "$CFG"

# 3) systemd-сервис (постоянный, переживает ребут)
cat > "$UNIT" <<UNITEOF
[Unit]
Description=xray RU-relay (planB) -> ${FOREIGN_IP}
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=$BIN run -config $CFG
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
UNITEOF

# 4) firewall + запуск
ufw allow "${RELAY_PORT}"/tcp >/dev/null 2>&1 || true
systemctl stop xray-relay-test 2>/dev/null || true   # убираем временный тестовый юнит
systemctl reset-failed xray-relay-test 2>/dev/null || true
systemctl daemon-reload
systemctl enable --now xray-relay >/dev/null 2>&1
sleep 1
echo "--- итог ---"
echo "xray-relay: $(systemctl is-active xray-relay) ($(systemctl is-enabled xray-relay))"
ss -tlnp 2>/dev/null | grep -q ":${RELAY_PORT}" && echo "LISTENING :${RELAY_PORT} OK" || echo "ВНИМАНИЕ: :${RELAY_PORT} не слушается"
