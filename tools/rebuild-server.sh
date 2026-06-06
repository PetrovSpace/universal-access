#!/usr/bin/env bash
# rebuild-server.sh — обновить сервер из main и сразу забрать конфиги в local/clients/.
# Одна команда = git reset --hard origin/main + install.sh + забор конфигов.
# Идемпотентность держится на /opt/access/state/ (UUID/ключи/shortId сохраняются),
# а список клиентов — на /opt/access/src/config.env (он в .gitignore, reset его не трогает).
# Запуск:  bash universal-access/tools/rebuild-server.sh   (алиас krm-rebuild)
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"

echo "== 1/2 Обновляю сервер (git reset --hard origin/main + install.sh) =="
ssh access 'set -e
  cd /opt/access/src && git fetch origin && git reset --hard origin/main && bash install.sh'

echo "== 2/2 Забираю конфиги в local/clients =="
bash "$HERE/pull-configs.sh"

echo "✓ Готово: сервер обновлён, конфиги в local/clients."
