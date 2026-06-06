# Changelog

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
