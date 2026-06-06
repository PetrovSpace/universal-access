# Заметки для разработки

## Bash под `set -euo pipefail` — грабли, проверенные на этом проекте

Все скрипты идут с `set -euo pipefail`. Классы багов, которые НЕ ловятся `bash -n`/smoke и
проявляются только на живом запуске (исправлены, но легко вернуть):

1. **SIGPIPE под pipefail.** `var=$(producer | consumer_with_early_exit)` — если потребитель
   (`awk '…; exit'`, `head`) закрывает пайп раньше, producer получает SIGPIPE (код 141), а
   `pipefail`+`set -e` молча роняют скрипт. Лечение: захватить вывод в переменную, парсить через
   here-string (`<<<`), а не пайпом.
2. **`cond && cmd` последней командой функции/цикла.** Если `cond` ложно, конструкция вернёт 1 →
   функция вернёт 1 → голый вызов под `set -e` уронит скрипт. Лечение: `if cond; then cmd; fi`
   и явный `return 0`.
3. **Формат конфига Xray по расширению.** `xray run -test -config FILE` определяет формат по
   расширению; временный файл должен быть `*.json` (иначе «Failed to get format»). Используем
   `mktemp --suffix=.json` с фолбэком на переименование.
4. **`printf` и дефисы.** `printf '----…'` трактует `--` как опции → «invalid option». Лечение:
   `printf -- '----…'`.

## Грабли конфигов Xray/Reality (тоже проверены)

- **gRPC/XHTTP — без `flow`.** `xtls-rprx-vision` только для raw-TCP. Для gRPC/XHTTP поле `flow`
  должно ОТСУТСТВОВАТЬ; пустая строка `"flow":""` может ломать строгие парсеры — не добавляем её.
- **Явное catch-all правило роутинга.** Не полагаться на «несопоставленное идёт в первый
  outbound» — добавлять финальное `{"type":"field","network":"tcp,udp","outboundTag":"proxy"}`.
- **Права на клиентские файлы.** В них UUID/ключи — создавать сразу `0600` (без TOCTOU-окна между
  созданием и `chmod`).
- **SNI для Reality.** Иностранный домен с TLS 1.3 + HTTP/2, не хостящийся в РФ. RU-домен на
  иностранном IP (особенно банки) — детектируется по несоответствию IP↔SNI.

## Персистентное состояние (`STATE_DIR`, по файлу на ключ)

Эти ключи — источник истины; **не удалять вручную**, иначе клиентам понадобятся новые
конфиги/ссылки:

```
xray_reality_private, xray_reality_public,
xray_uuid_<client>,
xray_shortid_blacklist, xray_shortid_whitelist, xray_shortid_grpc,
xray_sni_blacklist, xray_sni_whitelist,
awg_server_private, awg_peer_{private,pub,psk,ip}_<peer>,
awg_port, mtproto_port, mtproto_secret
```

При миграции старого сервера на gRPC-версию инсталлятора: если `xray_shortid_grpc` отсутствует,
`install.sh` сгенерит НОВЫЙ shortId и сломает уже розданные gRPC-конфиги. Чтобы сохранить
существующие — заранее засеять прежним значением:
`echo <старый_shortid> > $STATE_DIR/xray_shortid_grpc` перед `install.sh`.

## Идемпотентность

`install.sh` можно гонять повторно — он не дублирует и не пересоздаёт существующие ключи.
Добавление клиента/устройства = дописать в массивы `CLIENTS`/`AWG_PEERS` в `config.env` и
перезапустить `install.sh` (создаст только новых).
