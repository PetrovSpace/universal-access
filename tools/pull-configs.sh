#!/usr/bin/env bash
# pull-configs.sh — забрать клиентские конфиги с сервера в local/clients/ (зеркало сервера).
# Имена файлов = как на сервере (по списку CLIENTS в его config.env). SUMMARY.txt → local/docs/.
# Использует SSH-алиас `access`.
# Запуск:  bash universal-access/tools/pull-configs.sh   (алиас krm-sync)
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
DEST="$REPO/local/clients"
DOCS="$REPO/local/docs"
mkdir -p "$DEST" "$DOCS"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

echo "→ Качаю /opt/access/clients/* с сервера (ssh access)…"
scp -q "access:/opt/access/clients/*" "$TMP/" \
  || { echo "Ошибка scp. Проверь, что работает 'ssh access'."; exit 1; }

# Зеркало сервера: чистим прежние конфиги, чтобы не копились устаревшие имена.
rm -f "$DEST"/* 2>/dev/null || true

n=0
for f in "$TMP"/*; do
  [ -f "$f" ] || continue
  b="$(basename "$f")"
  if [ "$b" = "SUMMARY.txt" ]; then dest="$DOCS/SUMMARY.txt"; else dest="$DEST/$b"; fi
  install -m 600 "$f" "$dest"
  n=$((n+1))
done

echo "✓ Скопировано файлов: $n → $DEST"
echo "Основные для Happ (импорт как custom JSON):"
ls -1 "$DEST"/vless-grpc-*.json 2>/dev/null || echo "  (gRPC .json не найдены)"
