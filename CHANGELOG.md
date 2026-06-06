# Changelog

## 2026-06-06 — fix: NAT для AmneziaWG в управляемом nftables-ruleset

### Исправлено
- **AmneziaWG-клиенты не получали интернет** (хендшейк есть, трафик не ходит, DNS/сайты не
  открываются, роутер реконнектится каждые 1-2 мин). Корень: masquerade для подсети AWG жил
  только в `PostUp` awg-quick (iptables), а `_firewall_setup_nftables` в конце делает
  `systemctl restart nftables` → `/etc/nftables.conf` начинается с `flush ruleset` и сносит
  `table ip nat` с этим masquerade. После каждого `install.sh` NAT для AWG отваливался.
  Симптом в `awg show`: много `received`, почти ноль `sent` (сервер не генерит обратный трафик).
- Фикс: masquerade теперь в НАШЕЙ таблице `table inet access` (chain postrouting, `srcnat`),
  WAN-интерфейс определяется по default-маршруту. Переживает `restart nftables` и пересборки.

## 2026-06-06 — Реорганизация: операторские скрипты в git, личное в local/

### Добавлено
- **`tools/`** — операторские скрипты (запускаются с Mac/на релее), отдельно от
  серверных `bin/`: `pull-configs.sh` (забрать конфиги с сервера), `rebuild-server.sh`
  (обновить сервер из main + забрать конфиги), `ru-vantage-test.sh` (тест с РФ-вантажа),
  `install-relay.sh` (план Б — РФ-релей, **параметризован**: секреты из `local/relay.env`,
  шаблон — `tools/relay.env.example`).
- **`docs/promt-access-server-installer.md`** — исходное ТЗ проекта.

### Изменено
- `.gitignore`: добавлены `local/` и `.DS_Store`.
- Личные данные (готовые конфиги клиентов, заметки с реальными IP/ключами) вынесены в
  **`local/`** (в `.gitignore`) — `pull-configs.sh` кладёт конфиги в `local/clients/`.
  Прежняя внешняя папка `krm/` упразднена.
- `docs/testing.md`: путь скрипта обновлён на `tools/ru-vantage-test.sh`.
- `tools/rebuild-server.sh`: убран хардкод gRPC-shortId (идемпотентность держит `STATE_DIR`,
  список клиентов — закреплённый `config.env` на сервере).

## 2026-06-06 — gRPC как основной транспорт + документация

### Добавлено
- **VLESS+Reality поверх gRPC** на `:2053` — основной транспорт (обходит детект почерка raw-TCP
  абонентским/мобильным DPI РФ). raw-TCP `:443`/`:8443` оставлены как план Б.
- **`bin/gen-client-config.py`** — генератор Happ-конфигов: `--net grpc|tcp|xhttp`, `--frag`
  (TLS-фрагментация ClientHello), split-routing (RU-домены + `geoip:ru` напрямую, остальное в
  туннель, явное catch-all правило). Клиентам отдаётся `vless-grpc-<client>.json` (split-routing)
  + `.txt`-ссылка.
- **Документация** в [`docs/`](docs/): архитектура, диагностика обхода ТСПУ РФ, методика
  тестирования из РФ, заметки для разработки.

### Изменено
- `lib/firewall.sh` открывает `REALITY_PORT_GRPC`.
- `lib/common.sh`: дефолты/экспорт `REALITY_PORT_GRPC=2053`, `GRPC_SERVICE_NAME=grpc`.
- `install.sh`/`bin/info.sh`: сводка показывает gRPC основным, raw-TCP — планом Б.
- `bin/regen.sh`: чистит gRPC-артефакты клиента при перевыпуске.
- README: матрица каналов и приоритеты обновлены.

### Исправлено (по итогам adversarial-ревью)
- Убран пустой `"flow":""` для gRPC/XHTTP (ломал строгие парсеры).
- Явное catch-all routing-правило (не полагаемся на неявный «первый outbound»).
- Клиентские `.json` создаются сразу с правами `0600` (без TOCTOU-окна).
- `_xray_emit_split_json`: guard на пустые переменные, ошибки python больше не глотаются молча.

### Совместимость
Состояние идемпотентно: UUID/ключи/SNI берутся из `STATE_DIR`. При миграции старого сервера —
засеять `xray_shortid_grpc` прежним значением, иначе существующие gRPC-конфиги сломаются
(см. [docs/development.md](docs/development.md)).
