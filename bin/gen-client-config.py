#!/usr/bin/env python3
# gen-happ-config.py — генератор Happ-импортируемого xray-конфига со split-routing
# (RU-домены и RU-IP идут НАПРЯМУЮ, остальное — в туннель VLESS+Reality).
# Повторяет логику рабочих конфигов «чебурашки»: yandex/госуслуги/банки/маркетплейсы
# работают всегда (мимо туннеля), а заблокированное идёт через сервер.
#
# Использование:
#   python3 gen-happ-config.py --id UUID --host H --port P --sni S --pbk PBK --sid SID \
#       --net tcp|grpc --flow "xtls-rprx-vision"|"" --fp chrome --remark "..." --out file.json
import argparse, json, os, sys

# --- Базовые RU-суффиксы (один domain: покрывает все поддомены). --------------
# Взято из рабочих конфигов + добавлены очевидные банки/телеком/госы, которые
# обязаны идти НАПРЯМУЮ (иностранный egress их часто геоблокирует).
RU_DOMAINS = [
    # из рабочего конфига (дедуплицировано до суффиксов)
    "2gis.com","2gis.ru","47news.ru","alfabank.ru","vk-portal.net","premier.one",
    "okko.tv","auth-nsdi.ru","res-nsdi.ru","auto.ru","avito.ru","avito.st",
    "yandex.com","yandex.net","yandex.ru","ya.ru","yastatic.net",
    "cdn-vk.ru","cikrf.ru","izbirkom.ru","vk.com","vk.ru","userapi.com","okcdn.ru",
    "ok.ru","dzen.ru","gazeta.ru","gismeteo.com","gosuslugi.ru","gov.ru",
    "government.ru","gu-st.ru","kinopoisk.ru","kp.ru","kremlin.ru","lemanapro.ru",
    "lmru.tech","lenta.ru","lenta.com","mail.ru","max.ru","mradx.net","oneme.ru",
    "ozon.ru","ozone.ru","pochta.ru","rambler.ru","rbc.ru","rutube.ru",
    "rutubelist.ru","rzd.ru","t2.ru","taximaxim.ru","tutu.ru","vtb.ru","wb.ru",
    "wildberries.ru","hh.ru","xn--80ajghhoc2aj1c8b.xn--p1ai",
    # добавлено: банки/телеком/госы/прочее, чего нет в исходном списке
    "sberbank.ru","sber.ru","sbrf.ru","tinkoff.ru","tbank.ru","yoomoney.ru",
    "nalog.ru","nalog.gov.ru","mos.ru","mts.ru","megafon.ru","beeline.ru",
    "tele2.ru","rt.ru","gismeteo.ru","kaspersky.ru","drom.ru","cian.ru",
    "aliexpress.ru","sbermarket.ru","samokat.ru","dns-shop.ru","mvideo.ru",
    "citilink.ru","rutube.com","smotrim.ru","vgtrk.ru","1tv.ru","ntv.ru",
]

def _outbounds(args, stream):
    # flow используется ТОЛЬКО для TCP+Vision; для gRPC/XHTTP его быть не должно
    # (пустая строка "" ломает строгие парсеры). Поэтому добавляем поле лишь при непустом flow.
    user = {"id": args.id, "encryption": "none"}
    if args.flow:
        user["flow"] = args.flow
    obs = [
        {"protocol": "vless", "tag": "proxy",
         "settings": {"vnext": [{"address": args.host, "port": int(args.port),
                                 "users": [user]}]},
         "streamSettings": stream},
    ]
    # M1: freedom-outbound с фрагментацией; служит ТОЛЬКО дайлером для proxy.
    if args.frag:
        obs.append({"protocol": "freedom", "tag": "frag",
                    "settings": {"fragment": {"packets": args.frag_packets,
                                              "length": args.frag_length,
                                              "interval": args.frag_interval}}})
    obs.append({"protocol": "freedom", "tag": "direct"})
    obs.append({"protocol": "blackhole", "tag": "block"})
    return obs


def build(args):
    reality = {
        "fingerprint": args.fp, "publicKey": args.pbk,
        "serverName": args.sni, "shortId": args.sid, "spiderX": "/",
    }
    stream = {"network": args.net, "security": "reality", "realitySettings": reality}
    if args.net == "grpc":
        stream["grpcSettings"] = {"serviceName": args.grpc_service, "multiMode": False,
                                  "idle_timeout": 60, "health_check_timeout": 20,
                                  "permit_without_stream": True}
    elif args.net == "xhttp":
        stream["xhttpSettings"] = {"path": args.xhttp_path, "mode": args.xhttp_mode,
                                   "extra": {"xPaddingBytes": "100-1000"}}
    elif args.net == "tcp":
        stream["tcpSettings"] = {}
    # M1: TLS-фрагментация ClientHello — привязывается к proxy через dialerProxy.
    if args.frag:
        stream["sockopt"] = {"dialerProxy": "frag"}

    cfg = {
        "dns": {"queryStrategy": "UseIPv4",
                "servers": ["https://1.1.1.1/dns-query", "https://dns.google/dns-query"]},
        "inbounds": [
            {"tag": "socks", "listen": "127.0.0.1", "port": 10808, "protocol": "socks",
             "settings": {"auth": "noauth", "udp": True},
             "sniffing": {"enabled": True, "destOverride": ["http","tls","quic"]}},
            {"tag": "http", "listen": "127.0.0.1", "port": 10809, "protocol": "http",
             "settings": {"allowTransparent": False},
             "sniffing": {"enabled": True, "destOverride": ["http","tls","quic"]}},
        ],
        "log": {"loglevel": "warning"},
        "outbounds": _outbounds(args, stream),
        "remarks": args.remark,
        "routing": {
            "domainStrategy": "IPIfNonMatch",
            "rules": [
                {"type": "field", "protocol": ["bittorrent"], "outboundTag": "block"},
                {"type": "field", "domain": ["domain:"+d for d in RU_DOMAINS],
                 "outboundTag": "direct"},
                {"type": "field", "ip": ["geoip:ru", "geoip:private"],
                 "outboundTag": "direct"},
                # Явный catch-all: весь несопоставленный трафик — в туннель (не полагаемся
                # на неявный «первый outbound»).
                {"type": "field", "network": "tcp,udp", "outboundTag": "proxy"},
            ],
        },
    }
    return cfg

def main():
    p = argparse.ArgumentParser()
    p.add_argument("--id", required=True); p.add_argument("--host", required=True)
    p.add_argument("--port", required=True); p.add_argument("--sni", required=True)
    p.add_argument("--pbk", required=True); p.add_argument("--sid", default="")
    p.add_argument("--net", choices=["tcp","grpc","xhttp"], default="tcp")
    p.add_argument("--flow", default="xtls-rprx-vision")
    p.add_argument("--fp", default="chrome")
    p.add_argument("--grpc-service", default="grpc")
    p.add_argument("--xhttp-path", default="/")
    p.add_argument("--xhttp-mode", default="packet-up",
                   choices=["auto","packet-up","stream-up","stream-one"])
    p.add_argument("--frag", action="store_true",
                   help="включить TLS-фрагментацию ClientHello (dialerProxy->freedom+fragment)")
    p.add_argument("--frag-packets", default="tlshello")
    p.add_argument("--frag-length", default="100-200")
    p.add_argument("--frag-interval", default="10-20")
    p.add_argument("--remark", default="RU access")
    p.add_argument("--out", required=True)
    a = p.parse_args()
    cfg = build(a)
    # Создаём файл сразу с правами 0600 (в нём UUID/ключи) — без TOCTOU-окна.
    with open(a.out, "w", opener=lambda p, fl: os.open(p, fl, 0o600)) as f:
        json.dump(cfg, f, ensure_ascii=False, indent=2)
    print(f"written {a.out}  ({len(RU_DOMAINS)} RU-direct domains, net={a.net})")

if __name__ == "__main__":
    main()
