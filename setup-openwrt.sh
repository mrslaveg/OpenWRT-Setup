#!/bin/sh

# ============================================
#  Автоматическая настройка OpenWrt
#  SSClash + DNS Override + IPv6 off + NTP + WiFi
# ============================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()  { echo -e "${GREEN}[+]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
error(){ echo -e "${RED}[✗]${NC} $1"; exit 1; }
info() { echo -e "${CYAN}[i]${NC} $1"; }

[ "$(id -u)" -eq 0 ] || error "Скрипт нужно запускать от root"

echo "============================================"
echo "  Автоматическая настройка OpenWrt"
echo "============================================"
echo

# --------------------------------------------
# Определяем IP роутера
# --------------------------------------------
LAN_IP=$(uci -q get network.lan.ipaddr)
[ -z "$LAN_IP" ] && LAN_IP="192.168.1.1"
info "IP роутера: $LAN_IP"
echo

# --------------------------------------------
# Интерактивный ввод
# --------------------------------------------
echo -e "${CYAN}Введите данные для SSClash:${NC}"
echo

printf "Ссылка на подписку: "
read -r SUB_URL
[ -z "$SUB_URL" ] && error "Ссылка на подписку не может быть пустой"

printf "Секрет для дашборда (secret): "
read -r DASH_SECRET
[ -z "$DASH_SECRET" ] && error "Секрет не может быть пустым"

echo
log "Подписка: $SUB_URL"
log "Секрет:   $DASH_SECRET"
echo

# --------------------------------------------
# 1. Обновление системы
# --------------------------------------------
log "Обновление пакетов..."
apk update
apk upgrade

# --------------------------------------------
# 2. Отключение IPv6
# --------------------------------------------
log "Отключение IPv6..."

uci -q delete network.globals.ula_prefix
uci set network.lan.ip6assign='0'
uci -q delete network.lan.ip6hint
uci -q delete network.lan.ip6ifaceid
uci set network.wan.reqaddress='none'
uci set network.wan.reqprefix='no'
uci -q delete network.wan6

if uci -q show dhcp.lan >/dev/null 2>&1; then
    uci set dhcp.lan.dhcpv6='disabled'
    uci set dhcp.lan.ra='disabled'
    uci set dhcp.lan.ndp='disabled'
fi

if uci -q show dhcp.wan >/dev/null 2>&1; then
    uci set dhcp.wan.dhcpv6='disabled'
    uci set dhcp.wan.ra='disabled'
    uci set dhcp.wan.ndp='disabled'
fi

idx=0
while uci -q show "firewall.@rule[$idx]" >/dev/null 2>&1; do
    family=$(uci -q get "firewall.@rule[$idx].family" 2>/dev/null)
    if [ "$family" = "ipv6" ]; then
        uci delete "firewall.@rule[$idx]"
        continue
    fi
    idx=$((idx + 1))
done

uci commit network
uci commit dhcp
uci commit firewall

/etc/init.d/odhcpd disable 2>/dev/null || true
/etc/init.d/odhcpd stop 2>/dev/null || true
/etc/init.d/network restart
/etc/init.d/firewall restart

log "IPv6 отключён"

# --------------------------------------------
# 3. Установка SSClash
# --------------------------------------------
log "Установка SSClash..."
wget --no-proxy -qO- https://github.com/zerolabnet/SSClash/raw/refs/heads/main/install-ssclash.sh | ash

# --------------------------------------------
# 4. DNS Override (53 → 753)
# --------------------------------------------
log "Настройка DNS Override (порт 53 → 753)..."

uci add firewall redirect
uci set firewall.@redirect[-1].name='LAN DNS to Mihomo'
uci set firewall.@redirect[-1].src='lan'
uci set firewall.@redirect[-1].src_dport='53'
uci set firewall.@redirect[-1].dest_port='753'
uci set firewall.@redirect[-1].proto='tcp udp'
uci set firewall.@redirect[-1].family='ipv4'
uci set firewall.@redirect[-1].target='DNAT'
uci set firewall.@redirect[-1].dest='lan'
uci commit firewall
/etc/init.d/firewall restart

# --------------------------------------------
# 5. Правка /etc/init.d/clash
# --------------------------------------------
log "Исправление DNS-порта в /etc/init.d/clash..."

if [ -f /etc/init.d/clash ]; then
    sed -i 's/127\.0\.0\.1#7874/127.0.0.1#753/g' /etc/init.d/clash
    log "DNS-порт изменён на 753"
else
    warn "Файл /etc/init.d/clash не найден"
fi

# --------------------------------------------
# 6. NTP-серверы
# --------------------------------------------
log "Установка NTP-серверов..."

uci -q delete system.ntp.server
uci add_list system.ntp.server='0.ru.pool.ntp.org'
uci add_list system.ntp.server='1.ru.pool.ntp.org'
uci add_list system.ntp.server='ntp.ix.ru'
uci add_list system.ntp.server='ntp1.vniiftri.ru'
uci set system.ntp.enable_server='0'
uci commit system
/etc/init.d/sysntpd restart

# --------------------------------------------
# 7. Проброс порта 7777 → LAN_IP:80
# --------------------------------------------
log "Проброс порта 7777 → $LAN_IP:80..."

uci add firewall redirect
uci set firewall.@redirect[-1].name='Remote management'
uci set firewall.@redirect[-1].src='wan'
uci set firewall.@redirect[-1].src_dport='7777'
uci set firewall.@redirect[-1].dest='lan'
uci set firewall.@redirect[-1].dest_ip="$LAN_IP"
uci set firewall.@redirect[-1].dest_port='80'
uci set firewall.@redirect[-1].proto='tcp'
uci set firewall.@redirect[-1].target='DNAT'
uci commit firewall
/etc/init.d/firewall restart

# --------------------------------------------
# 8. Включение Wi-Fi
# --------------------------------------------
log "Включение Wi-Fi..."

for radio in $(uci show wireless 2>/dev/null | grep '=wifi-device' | cut -d. -f2 | cut -d= -f1); do
    uci set wireless.$radio.disabled='0'
done

for iface in $(uci show wireless 2>/dev/null | grep '=wifi-iface' | cut -d. -f2 | cut -d= -f1); do
    uci set wireless.$iface.disabled='0'
done

uci commit wireless
wifi up 2>/dev/null || wifi reload 2>/dev/null || true

log "Wi-Fi включён"

# --------------------------------------------
# 9. Конфиг SSClash + генерация hwid
# --------------------------------------------
log "Запись конфига SSClash..."

if [ -f /proc/sys/kernel/random/uuid ]; then
    HWID=$(cat /proc/sys/kernel/random/uuid)
else
    HWID=$(hexdump -n 16 -e '4/4 "%08x" 1 "\n"' /dev/urandom | sed 's/\(........\)\(........\)\(........\)\(........\)/\1-\2-\3-\4/')
fi

log "Сгенерирован x-hwid: $HWID"

mkdir -p /opt/clash

# Экранируем спецсимволы в секрете
DASH_SECRET_ESC=$(printf '%s' "$DASH_SECRET" | sed 's/[\\"]/\\&/g')

cat > /opt/clash/config.yaml << EOF
mixed-port: 7892
redir-port: 7893
tproxy-port: 7894
# --- ОБЩИЕ НАСТРОЙКИ ЯДРА ---
allow-lan: true
mode: rule
log-level: silent
find-process-mode: off
ipv6: false
tcp-concurrent: true
external-ui: ui
external-controller: 0.0.0.0:9090
secret: "${DASH_SECRET_ESC}"
external-ui-url: "https://github.com/Zephyruso/zashboard/releases/latest/download/dist.zip"
global-ua: clash.meta
profile:
  store-selected: true
# --- НАСТРОЙКИ СНИФФЕРА ---
sniffer:
  enable: true
  force-dns-mapping: true
  parse-pure-ip: true
  sniff:
    HTTP:
      ports: [80, 8080-8880]
      override-destination: true
    TLS:
      ports: [443]
      override-destination: true
  skip-domain:
    - "+.fbcdn.net"
    - "+.wa.me"
    - "+.whatsapp.com"
    - "+.whatsapp.net"
    - "+.stel.com"
    - "+.t.me"
    - "+.tdesktop.com"
    - "+.telegra.ph"
    - "+.telegram.dog"
    - "+.telegram.me"
    - "+.telegram.org"
    - "+.telesco.pe"
    - "+.tg.dev"
    - "+.tx.me"
# --- DNS ---
dns:
  enable: true
  listen: 0.0.0.0:753
  ipv6: false
  cache-algorithm: arc
  default-nameserver:
    - 77.88.8.8
    - 8.8.8.8
  nameserver:
    - https://cloudflare-dns.com/dns-query#VPN
    - https://dns.google/dns-query#VPN
  nameserver-policy:
    'rule-set:geosite-ru':
      - https://common.dot.dns.yandex.net/dns-query
    'rule-set:direct':
      - https://common.dot.dns.yandex.net/dns-query
    'rule-set:games':
      - https://common.dot.dns.yandex.net/dns-query
    '+.ru,+.su,+.xn--p1ai,+.moscow,+.xn--80adxhks,+.tatar':
      - https://common.dot.dns.yandex.net/dns-query
# --- ПРОВАЙДЕРЫ ПРАВИЛ ---
rule-providers:
  direct:
    type: http
    behavior: domain
    format: mrs
    url: "https://raw.githubusercontent.com/mrslaveg/mihomo-rule-sets/main/direct.mrs"
    path: ./rules/direct.mrs
    interval: 3600
  games:
    type: http
    behavior: domain
    format: mrs
    url: "https://raw.githubusercontent.com/mrslaveg/mihomo-rule-sets/main/games.mrs"
    path: ./rules/games.mrs
    interval: 3600
  games-ip:
    type: http
    behavior: ipcidr
    format: mrs
    url: "https://raw.githubusercontent.com/mrslaveg/mihomo-rule-sets/main/gamesip.mrs"
    path: ./rules/games-ip.mrs
    interval: 3600
  proxy:
    type: http
    behavior: domain
    format: mrs
    url: "https://raw.githubusercontent.com/mrslaveg/mihomo-rule-sets/main/proxy.mrs"
    path: ./rules/proxy.mrs
    interval: 3600
  geosite-ru:
    type: http
    behavior: domain
    format: mrs
    url: "https://raw.githubusercontent.com/Davoyan/mihomo-rule-sets/main/rules/category-ru.mrs"
    path: ./rules/geosite-ru.mrs
    interval: 86400
  geoip-ru:
    type: http
    behavior: ipcidr
    format: mrs
    url: "https://raw.githubusercontent.com/Davoyan/mihomo-rule-sets/main/ip-for-ru/lists/ips-for-ru.mrs"
    path: ./rules/geoip-ru.mrs
    interval: 86400
# --- ПРОВАЙДЕРЫ ПРОКСИ ---
proxy-providers:
  FastConnect:
    type: http
    url: "${SUB_URL}"
    interval: 3600
    health-check:
      enable: true
      url: https://cp.cloudflare.com
      interval: 300
    exclude-filter: "LTE"
    header:
      x-hwid:
        - "${HWID}"
      x-device-os:
        - "OpenWrt 25.12.x"
      x-ver-os:
        - "SSClash 4.7.0"
      x-device-model:
        - "Cudy WR3000S"
      User-Agent:
        - "mihomo/1.19 (OpenWrt; like Clash Meta)"
proxies: []
proxy-groups:
  - name: VPN
    type: select
    proxies:
      - PROXY AUTO
      - PROXY MANUAL
      - DIRECT
  - name: PROXY AUTO
    type: fallback
    proxies:
      - PROXY BEST
      - DIRECT
    url: https://cp.cloudflare.com
    interval: 60
    lazy: false
  - name: PROXY BEST
    type: url-test
    use:
      - FastConnect
    url: https://cp.cloudflare.com
    interval: 60
    tolerance: 50
    lazy: false
  - name: PROXY MANUAL
    type: select
    use:
      - FastConnect
  - name: GLOBAL
    type: select
    hidden: true
    proxies:
      - PROXY AUTO
      - PROXY MANUAL
      - PROXY BEST
      - DIRECT
# --- ПРАВИЛА МАРШРУТИЗАЦИИ ---
rules:
  - IP-CIDR,10.0.0.0/8,DIRECT,no-resolve
  - IP-CIDR,172.16.0.0/12,DIRECT,no-resolve
  - IP-CIDR,192.168.0.0/16,DIRECT,no-resolve
  - IP-CIDR,127.0.0.0/8,DIRECT,no-resolve
  - IP-CIDR,100.64.0.0/10,DIRECT,no-resolve
  - IP-CIDR,169.254.0.0/16,DIRECT,no-resolve
  - RULE-SET,direct,DIRECT
  - RULE-SET,geosite-ru,DIRECT
  - RULE-SET,geoip-ru,DIRECT,no-resolve
  - RULE-SET,games,DIRECT
  - RULE-SET,games-ip,DIRECT,no-resolve
  - AND,((NETWORK,UDP),(DST-PORT,443)),REJECT-DROP
  - RULE-SET,proxy,VPN
  - DST-PORT,6881-6889,DIRECT
  - DST-PORT,51413,DIRECT
  - MATCH,VPN
EOF

log "Конфиг записан в /opt/clash/config.yaml"

if [ -f /etc/init.d/clash ]; then
    /etc/init.d/clash restart 2>/dev/null || true
fi

# --------------------------------------------
# Финал
# --------------------------------------------
echo
echo "============================================"
log "Настройка завершена!"
echo "============================================"
echo
echo "Сделано:"
echo "  • Система обновлена"
echo "  • IPv6 отключён"
echo "  • SSClash установлен"
echo "  • DNS 53 → 753"
echo "  • NTP-серверы установлены"
echo "  • Порт 7777 → $LAN_IP:80"
echo "  • Wi-Fi включён"
echo "  • Конфиг SSClash записан"
echo "      Подписка : $SUB_URL"
echo "      Секрет   : $DASH_SECRET"
echo "      hwid     : $HWID"
echo
info "Роутер:   http://$LAN_IP"
info "Дашборд:  http://$LAN_IP:9090/ui"
echo

# Вопрос о перезагрузке
printf "Перезагрузить роутер сейчас? [y/N]: "
read -r REBOOT_ANS
case "$REBOOT_ANS" in
    y|Y|yes|YES|да|ДА)
        log "Перезагрузка..."
        # Удаляем скрипт перед ребутом
        rm -f /tmp/setup-openwrt.sh 2>/dev/null || true
        sleep 1
        reboot
        ;;
    *)
        info "Перезагрузка отложена"
        # Удаляем скрипт
        rm -f /tmp/setup-openwrt.sh 2>/dev/null || true
        log "Скрипт удалён из /tmp"
        ;;
esac

echo
