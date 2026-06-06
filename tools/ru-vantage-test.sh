#!/usr/bin/env bash
# ru-vantage-test.sh — проверка VLESS+Reality с ТЕКУЩЕГО вантажа (где запущен скрипт).
# Запускать НА российском Linux-VPS/устройстве. Поднимает headless-клиент xray (SOCKS)
# и сравнивает: прямой доступ vs доступ через туннель. Если через туннель внешний IP
# становится серверным и заблокированный ресурс открывается — Reality пробивает отсюда.
#
# ВАЖНО: датацентр-VPS за ТСПУ фильтруется ИНАЧЕ, чем мобильный оператор. «Прошёл на VPS»
# != «пройдёт на мобильном». «Заблокирован на VPS» — очень показательно. Мобильный режим
# (whitelist :8443) надёжно проверяется только на реальном телефоне с мобильным интернетом.
#
# Использование:
#   ./ru-vantage-test.sh 'vless://...ссылка из vless-reality-*.txt...' [URL_который_у_тебя_заблокирован]
set -euo pipefail

LINK="${1:?Передай vless:// ссылку первым аргументом (из vless-reality-*.txt или vless-whitelist-*.txt)}"
TEST_URL="${2:-https://www.instagram.com}"   # ← подставь ресурс, который у ТЕБЯ реально заблокирован
SOCKS_PORT=10808

# --- разбор vless:// ссылки -------------------------------------------------
r="${LINK#vless://}"
UUID="${r%%@*}"; r="${r#*@}"
hp="${r%%\?*}"; HOST="${hp%%:*}"; PORT="${hp##*:}"
q="${r#*\?}"; q="${q%%#*}"
val(){ printf '%s' "$q" | tr '&' '\n' | sed -n "s/^$1=//p" | head -1; }
SNI=$(val sni); PBK=$(val pbk); SID=$(val sid); FLOW=$(val flow); FP=$(val fp)
SPX=$(val spx); SPX="${SPX//%2F//}"; SPX="${SPX:-/}"
[ -n "${SNI:-}" ] && [ -n "${PBK:-}" ] || { echo "Ошибка: не разобрал ссылку (sni/pbk пусты)."; exit 1; }
echo "Цель: ${HOST}:${PORT}  sni=${SNI}  flow=${FLOW}  fp=${FP}  sid=${SID}"

# --- портативный xray во временную папку ------------------------------------
TMP=$(mktemp -d); XPID=""
cleanup(){ [ -n "$XPID" ] && kill "$XPID" 2>/dev/null || true; rm -rf "$TMP"; }
trap cleanup EXIT
if command -v xray >/dev/null 2>&1; then
  XRAY=xray
else
  command -v unzip >/dev/null 2>&1 || { echo "Нужен unzip: sudo apt-get install -y unzip"; exit 1; }
  echo "Скачиваю xray-core (портативно)..."
  curl -fsSL -o "$TMP/x.zip" https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip
  unzip -q "$TMP/x.zip" -d "$TMP"; XRAY="$TMP/xray"; chmod +x "$XRAY"
fi

# --- конфиг клиента ---------------------------------------------------------
cat >"$TMP/c.json" <<JSON
{
  "log": {"loglevel":"warning"},
  "inbounds": [{"tag":"socks","listen":"127.0.0.1","port":${SOCKS_PORT},"protocol":"socks","settings":{"udp":true}}],
  "outbounds": [{
    "protocol":"vless",
    "settings":{"vnext":[{"address":"${HOST}","port":${PORT},"users":[{"id":"${UUID}","encryption":"none","flow":"${FLOW}"}]}]},
    "streamSettings":{"network":"tcp","security":"reality",
      "realitySettings":{"serverName":"${SNI}","fingerprint":"${FP}","publicKey":"${PBK}","shortId":"${SID}","spiderX":"${SPX}"}}
  }]
}
JSON
"$XRAY" run -test -config "$TMP/c.json" >/dev/null 2>&1 || { echo "Ошибка: конфиг клиента невалиден."; exit 1; }
"$XRAY" run -config "$TMP/c.json" >"$TMP/xray.log" 2>&1 & XPID=$!
sleep 2
kill -0 "$XPID" 2>/dev/null || { echo "xray не запустился:"; cat "$TMP/xray.log"; exit 1; }

S="--socks5-hostname 127.0.0.1:${SOCKS_PORT}"
echo
echo "=== 1) ПРЯМОЙ доступ с этого вантажа (без туннеля) ==="
printf "  внешний IP : "; curl -s --max-time 10 https://api.ipify.org 2>/dev/null || echo "(нет ответа)"; echo
printf "  %s : " "$TEST_URL"; curl -s --max-time 12 -o /dev/null -w "HTTP %{http_code}, %{time_total}s\n" "$TEST_URL" 2>/dev/null || echo "ЗАБЛОКИРОВАН / таймаут"

echo
echo "=== 2) Через ТУННЕЛЬ VLESS+Reality (${HOST}) ==="
printf "  внешний IP : "; curl -s --max-time 12 $S https://api.ipify.org 2>/dev/null || echo "(нет ответа)"; echo
printf "  %s : " "$TEST_URL"; curl -s --max-time 15 $S -o /dev/null -w "HTTP %{http_code}, %{time_total}s\n" "$TEST_URL" 2>/dev/null || echo "не открылся"

echo
echo "ИТОГ: если через туннель внешний IP = ${HOST} и заблокированный ресурс открылся —"
echo "      VLESS+Reality пробивает с этого вантажа. Для мобильного режима тестируй на телефоне с :8443."
