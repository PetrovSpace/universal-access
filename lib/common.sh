#!/usr/bin/env bash
# lib/common.sh — общие функции, пути и определение окружения.
# Источаемый модуль: на source выставляет глобальные пути и цвета.
set -euo pipefail

# --- Глобальные пути (используются во всех модулях и bin/*) -------------------
ACCESS_DIR="${ACCESS_DIR:-/opt/access}"
SRC_DIR="${SRC_DIR:-$ACCESS_DIR/src}"
CLIENTS_DIR="${CLIENTS_DIR:-$ACCESS_DIR/clients}"
STATE_DIR="${STATE_DIR:-$ACCESS_DIR/state}"
LOG_FILE="${LOG_FILE:-$ACCESS_DIR/install.log}"
export ACCESS_DIR SRC_DIR CLIENTS_DIR STATE_DIR LOG_FILE

# --- Цвета (без цвета, если stdout не TTY) -----------------------------------
if [[ -t 2 ]]; then
  C_RESET=$'\033[0m'; C_RED=$'\033[0;31m'; C_GRN=$'\033[0;32m'
  C_YEL=$'\033[0;33m'; C_BLU=$'\033[0;34m'; C_BOLD=$'\033[1m'
else
  C_RESET=''; C_RED=''; C_GRN=''; C_YEL=''; C_BLU=''; C_BOLD=''
fi

# --- Логирование (в stderr + дозапись в LOG_FILE) ----------------------------
_log_to_file() {
  # Пишем в лог без цветовых кодов; каталог может ещё не существовать.
  local dir; dir=$(dirname "$LOG_FILE")
  [[ -d $dir ]] || mkdir -p "$dir" 2>/dev/null || return 0
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >>"$LOG_FILE" 2>/dev/null || true
}

log_info()  { printf '%s[*]%s %s\n' "$C_BLU" "$C_RESET" "$*" >&2; _log_to_file "[INFO] $*"; }
log_warn()  { printf '%s[!]%s %s\n' "$C_YEL" "$C_RESET" "$*" >&2; _log_to_file "[WARN] $*"; }
log_error() { printf '%s[x]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; _log_to_file "[ERROR] $*"; }
log_ok()    { printf '%s[+]%s %s\n' "$C_GRN" "$C_RESET" "$*" >&2; _log_to_file "[OK] $*"; }
log_step()  { printf '\n%s==>%s %s%s%s\n' "$C_BOLD" "$C_RESET" "$C_BOLD" "$*" "$C_RESET" >&2; _log_to_file "[STEP] $*"; }

die() { log_error "$*"; exit 1; }

require_root() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] || die "Требуются права root. Запустите от root (sudo)."
}

# --- Установка пакетов (apt) -------------------------------------------------
_APT_UPDATED=0
apt_update_once() {
  [[ $_APT_UPDATED -eq 1 ]] && return 0
  log_info "apt-get update..."
  DEBIAN_FRONTEND=noninteractive apt-get update -y >/dev/null 2>&1 \
    || die "Не удалось выполнить apt-get update."
  _APT_UPDATED=1
}

ensure_packages() {
  # Идемпотентно: ставим только отсутствующие пакеты.
  local pkg missing=()
  for pkg in "$@"; do
    if ! dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q 'install ok installed'; then
      missing+=("$pkg")
    fi
  done
  [[ ${#missing[@]} -eq 0 ]] && return 0
  apt_update_once
  log_info "Установка пакетов: ${missing[*]}"
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${missing[@]}" >/dev/null 2>&1 \
    || die "Не удалось установить пакеты: ${missing[*]}"
}

try_packages() {
  # Как ensure_packages, но НЕ убивает скрипт: возвращает ненулевой код при
  # неудаче. Для путей с фолбэком (AmneziaWG dkms->headers->go, firewall nft->ufw),
  # где недоступность пакета должна вести к запасному варианту, а не к остановке.
  local pkg missing=()
  for pkg in "$@"; do
    dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q 'install ok installed' || missing+=("$pkg")
  done
  [[ ${#missing[@]} -eq 0 ]] && return 0
  if [[ ${_APT_UPDATED:-0} -ne 1 ]]; then
    DEBIAN_FRONTEND=noninteractive apt-get update -y >/dev/null 2>&1 && _APT_UPDATED=1 || true
  fi
  log_info "Установка пакетов (с фолбэком при неудаче): ${missing[*]}"
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${missing[@]}" >/dev/null 2>&1
}

# --- Определение ОС ----------------------------------------------------------
detect_os() {
  [[ -r /etc/os-release ]] || die "Файл /etc/os-release не найден — неподдерживаемая система."
  # shellcheck disable=SC1091
  . /etc/os-release
  OS_ID="${ID:-}"
  OS_VERSION_ID="${VERSION_ID:-}"
  OS_CODENAME="${VERSION_CODENAME:-}"
  case "$OS_ID" in
    ubuntu|debian) PKG_MGR=apt ;;
    *) die "Неподдерживаемый дистрибутив: '${OS_ID}'. Нужен Ubuntu 24.04 или Debian 12." ;;
  esac
  command -v apt-get >/dev/null 2>&1 || die "apt-get не найден — ожидается Debian/Ubuntu."
  export OS_ID OS_VERSION_ID OS_CODENAME PKG_MGR
  log_ok "ОС: ${OS_ID} ${OS_VERSION_ID} (${OS_CODENAME:-?}), менеджер пакетов: ${PKG_MGR}"
}

# --- Определение публичного IP (несколько источников с фолбэком) -------------
detect_public_ip() {
  if [[ -n "${PUBLIC_IP:-}" ]]; then
    log_ok "PUBLIC_IP задан вручную: ${PUBLIC_IP}"
    export PUBLIC_IP
    return 0
  fi
  command -v curl >/dev/null 2>&1 || ensure_packages curl ca-certificates
  local src ip
  for src in \
    'https://api.ipify.org' \
    'https://ifconfig.me/ip' \
    'https://ipinfo.io/ip' \
    'https://icanhazip.com'; do
    ip=$(curl -fsS --max-time 8 "$src" 2>/dev/null | tr -d '[:space:]') || ip=''
    if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      PUBLIC_IP="$ip"
      export PUBLIC_IP
      log_ok "Публичный IP: ${PUBLIC_IP} (источник: ${src})"
      return 0
    fi
  done
  die "Не удалось определить публичный IP. Задайте PUBLIC_IP в config.env."
}

# --- Определение сетевого интерфейса по умолчанию ----------------------------
detect_default_iface() {
  local iface
  iface=$(ip -4 route show default 2>/dev/null | awk '/default/ {for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
  [[ -z "$iface" ]] && iface=$(ip route show default 2>/dev/null | awk '/default/ {for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
  [[ -n "$iface" ]] || die "Не удалось определить сетевой интерфейс по умолчанию."
  DEFAULT_IFACE="$iface"
  export DEFAULT_IFACE
  log_ok "Интерфейс по умолчанию: ${DEFAULT_IFACE}"
}

# --- Порты -------------------------------------------------------------------
is_port_free() {
  # is_port_free PORT PROTO ; 0 если порт свободен.
  local port="$1" proto="${2:-tcp}" flag
  case "$proto" in
    tcp) flag='-tln' ;;
    udp) flag='-uln' ;;
    *) die "is_port_free: неизвестный протокол '$proto'" ;;
  esac
  if command -v ss >/dev/null 2>&1; then
    ! ss "$flag" 2>/dev/null | awk '{print $5}' | grep -Eq "[:.]${port}\$"
  elif command -v netstat >/dev/null 2>&1; then
    ! netstat "$flag" 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]${port}\$"
  else
    ensure_packages iproute2
    ! ss "$flag" 2>/dev/null | awk '{print $5}' | grep -Eq "[:.]${port}\$"
  fi
}

find_free_port() {
  # find_free_port START PROTO ; печатает первый свободный порт >= START.
  local start="$1" proto="${2:-tcp}" port
  for ((port=start; port<=65535; port++)); do
    if is_port_free "$port" "$proto"; then
      printf '%s\n' "$port"
      return 0
    fi
  done
  die "Не найдено свободного ${proto}-порта начиная с ${start}."
}

# --- Генераторы секретов -----------------------------------------------------
gen_uuid() {
  if command -v uuidgen >/dev/null 2>&1; then
    uuidgen
  elif [[ -r /proc/sys/kernel/random/uuid ]]; then
    cat /proc/sys/kernel/random/uuid
  else
    ensure_packages uuid-runtime
    uuidgen
  fi
}

gen_hex() {
  # gen_hex N : печатает N hex-символов.
  local n="$1"
  openssl rand -hex "$(( (n + 1) / 2 ))" 2>/dev/null | cut -c "1-${n}"
}

gen_b64() {
  # gen_b64 N : печатает N url-safe base64-символов.
  local n="$1" out
  out=$(openssl rand -base64 "$(( n * 3 / 4 + 3 ))" 2>/dev/null | tr '+/' '-_' | tr -d '=\n') || out=''
  printf '%s\n' "${out:0:n}"
}

# --- Состояние (идемпотентность) ---------------------------------------------
state_init() {
  mkdir -p "$STATE_DIR" "$CLIENTS_DIR" || die "Не удалось создать каталоги состояния."
  chmod 0700 "$STATE_DIR" "$CLIENTS_DIR" || true
  # Базовый каталог тоже создаём, если ещё нет.
  mkdir -p "$ACCESS_DIR" "$SRC_DIR" 2>/dev/null || true
}

_state_key_path() {
  # Защита от выхода за пределы STATE_DIR через имя ключа.
  local key="$1"
  [[ "$key" == */* || "$key" == '.'* ]] && die "Недопустимое имя ключа состояния: '$key'"
  printf '%s/%s\n' "$STATE_DIR" "$key"
}

state_get() {
  local f; f=$(_state_key_path "$1")
  [[ -f "$f" ]] && cat "$f" || true
}

state_set() {
  local f; f=$(_state_key_path "$1")
  [[ -d $STATE_DIR ]] || state_init
  printf '%s' "$2" >"$f" || die "Не удалось записать состояние '$1'."
  chmod 0600 "$f" || true
}

state_get_or_create() {
  # state_get_or_create KEY CMD... — главный примитив идемпотентности.
  # Если ключ есть — печатаем его; иначе выполняем CMD, сохраняем stdout, печатаем.
  local key="$1"; shift
  local f; f=$(_state_key_path "$key")
  if [[ -f "$f" ]]; then
    cat "$f"
    return 0
  fi
  [[ $# -ge 1 ]] || die "state_get_or_create '$key': не передана команда генерации."
  local value
  value=$("$@") || die "state_get_or_create '$key': команда генерации завершилась с ошибкой."
  state_set "$key" "$value"
  printf '%s' "$value"
}

# --- Сетевой тюнинг ----------------------------------------------------------
enable_bbr() {
  # BBR + fq через sysctl drop-in; идемпотентно.
  local f=/etc/sysctl.d/99-access-bbr.conf
  modprobe tcp_bbr 2>/dev/null || true
  if ! grep -q 'tcp_bbr' /etc/modules-load.d/access-bbr.conf 2>/dev/null; then
    echo 'tcp_bbr' >/etc/modules-load.d/access-bbr.conf 2>/dev/null || true
  fi
  cat >"$f" <<'EOF'
# Управление перегрузкой BBR + планировщик fq (access server).
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
  sysctl -p "$f" >/dev/null 2>&1 || log_warn "sysctl: не все BBR-параметры применились (возможно после ребута)."
  local cc; cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo '?')
  log_ok "BBR: текущий congestion control = ${cc}"
}

tune_sysctl() {
  # Разумный сетевой тюнинг; идемпотентно (drop-in перезаписывается).
  local f=/etc/sysctl.d/98-access-tune.conf
  cat >"$f" <<'EOF'
# Сетевой тюнинг для access server (форвардинг + буферы).
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
net.core.rmem_max = 26214400
net.core.wmem_max = 26214400
net.core.netdev_max_backlog = 16384
net.core.somaxconn = 8192
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.udp_rmem_min = 8192
net.ipv4.udp_wmem_min = 8192
net.ipv4.tcp_rmem = 4096 87380 26214400
net.ipv4.tcp_wmem = 4096 65536 26214400
fs.file-max = 1000000
EOF
  sysctl -p "$f" >/dev/null 2>&1 || log_warn "sysctl: часть параметров тюнинга не применилась."
  log_ok "Применён сетевой тюнинг sysctl."
}

# --- Загрузка конфигурации + дефолты -----------------------------------------
load_config() {
  # Источаем config.env из SRC_DIR или текущего каталога, затем применяем дефолты.
  local cfg
  for cfg in "$SRC_DIR/config.env" "./config.env"; do
    if [[ -f "$cfg" ]]; then
      log_info "Загрузка конфигурации: ${cfg}"
      # shellcheck disable=SC1090
      . "$cfg"
      break
    fi
  done

  # Клиенты и устройства (массивы — задаём только если не определены).
  if ! declare -p CLIENTS >/dev/null 2>&1; then CLIENTS=("andrey" "wife"); fi
  if ! declare -p AWG_PEERS >/dev/null 2>&1; then AWG_PEERS=("mac" "keenetic" "windows"); fi

  # AmneziaWG.
  : "${AWG_PORT:=51820}"
  : "${AWG_SUBNET:=10.13.13.0/24}"
  # Обфускация AmneziaWG 2.0 (дефолты Amnezia, переопределяемы).
  : "${AWG_JC:=4}"
  : "${AWG_JMIN:=40}"
  : "${AWG_JMAX:=70}"
  : "${AWG_S1:=0}"
  : "${AWG_S2:=0}"
  : "${AWG_H1:=1}"
  : "${AWG_H2:=2}"
  : "${AWG_H3:=3}"
  : "${AWG_H4:=4}"
  : "${AWG_MTU:=1420}"

  # VLESS + Reality.
  : "${REALITY_PORT_BLACKLIST:=443}"
  : "${REALITY_PORT_WHITELIST:=8443}"
  if ! declare -p REALITY_SNI_BLACKLIST >/dev/null 2>&1; then
    REALITY_SNI_BLACKLIST=("www.microsoft.com" "www.cloudflare.com" "www.amazon.com")
  fi
  if ! declare -p REALITY_SNI_WHITELIST >/dev/null 2>&1; then
    REALITY_SNI_WHITELIST=("gosuslugi.ru" "www.gosuslugi.ru" "www.sberbank.ru")
  fi

  # MTProto (mtg, fake-TLS). 8888 по умолчанию, чтобы не конфликтовать с 8443.
  : "${MTPROTO_PORT:=8888}"
  : "${MTPROTO_MASK_DOMAIN:=www.cloudflare.com}"

  # Hysteria2 (опционально, по умолчанию выключен).
  : "${ENABLE_HYSTERIA2:=false}"
  : "${HYSTERIA2_PORT:=36712}"

  export AWG_PORT AWG_SUBNET AWG_JC AWG_JMIN AWG_JMAX AWG_S1 AWG_S2 \
         AWG_H1 AWG_H2 AWG_H3 AWG_H4 AWG_MTU \
         REALITY_PORT_BLACKLIST REALITY_PORT_WHITELIST \
         MTPROTO_PORT MTPROTO_MASK_DOMAIN ENABLE_HYSTERIA2 HYSTERIA2_PORT
}
