#!/bin/sh

# ============================================
#  Автоматическая настройка OpenWrt
#  SSClash + DNS Override + IPv6 off + NTP + WiFi + RU
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
# Определяем IP роутера (без маски)
# --------------------------------------------
LAN_IP=$(uci -q get network.lan.ipaddr | cut -d'/' -f1)
[ -z "$LAN_IP" ] && LAN_IP="192.168.1.1"
info "IP роутера: $LAN_IP"
echo

# --------------------------------------------
# Интерактивный ввод
# --------------------------------------------
echo -e "${CYAN}Введите данные:${NC}"
echo

printf "Ссылка на подписку: "
read -r SUB_URL
[ -z "$SUB_URL" ] && error "Ссылка на подписку не может быть пустой"

printf "Секрет для дашборда (secret): "
read -r DASH_SECRET
[ -z "$DASH_SECRET" ] && error "Секрет не может быть пустым"

printf "Пароль администратора (root/LuCI): "
read -r ROOT_PASS
[ -z "$ROOT_PASS" ] && error "Пароль не может быть пустым"

echo
log "Подписка : $SUB_URL"
log "Секрет   : $DASH_SECRET"
log "Пароль   : ********"
echo

# --------------------------------------------
# 1. Обновление системы + русский язык
# --------------------------------------------
log "Обновление пакетов..."
apk update
apk upgrade

log "Установка русского языка..."
apk add luci-i18n-base-ru 2>/dev/null || warn "Не удалось установить luci-i18n-base-ru"
uci set luci.main.lang='ru'
uci commit luci
log "Язык интерфейса: русский"

# --------------------------------------------
# 2. Установка пароля root
# --------------------------------------------
log "Установка пароля администратора..."
echo -e "$ROOT_PASS\n$ROOT_PASS" | passwd root
log "Пароль root установлен"

# --------------------------------------------
# 3. Отключение IPv6 (без network restart)
# --------------------------------------------
log "Отключение IPv6..."

set +e   # временно отключаем строгий режим

uci -q delete network.globals.ula_prefix
uci -q set network.lan.ip6assign='0'
uci -q delete network.lan.ip6hint
uci -q delete network.lan.ip6ifaceid

uci -q set network.wan.reqaddress='none'
uci -q set network.wan.reqprefix='no'
uci -q delete network.wan6

if uci -q show dhcp.lan >/dev/null 2>&1; then
    uci -q set dhcp.lan.dhcpv6='disabled'
    uci -q set dhcp.lan.ra='disabled'
    uci -q set dhcp.lan.ndp='disabled'
fi

if uci -q show dhcp.wan >/dev/null 2>&1; then
    uci -q set dhcp.wan.dhcpv6='disabled'
    uci -q set dhcp.wan.ra='disabled'
    uci -q set dhcp.wan.ndp='disabled'
fi

# Чистим IPv6-правила firewall
idx=0
while uci -q show "firewall.@rule[$idx]" >/dev/null 2>&1; do
    family=$(uci -q get "firewall.@rule[$idx].family" 2>/dev/null)
    if [ "$family" = "ipv6" ]; then
        uci -q delete "firewall.@rule[$idx]"
        continue
    fi
    idx=$((idx + 1))
done

uci -q commit network
uci -q commit dhcp
uci -q commit firewall

/etc/init.d/odhcpd disable
/etc/init.d/odhcpd stop
/etc/init.d/firewall restart

set -e   # возвращаем строгий режим

log "IPv6 отключён (сеть будет перезапущена позже)"

# --------------------------------------------
# 4. Установка SSClash
# --------------------------------------------
log "Установка SSClash..."
wget --no-proxy -qO- https://github.com/zerolabnet/SSClash/raw/refs/heads/main/install-ssclash.sh | ash

# --------------------------------------------
# 5. Перезаписываем config.yaml
# --------------------------------------------
log "Запись конфига SSClash (перезаписываем дефолтный)..."

if [ -f /proc/sys/kernel/random/uuid ]; then
    HWID=$(cat /proc/sys/kernel/random/uuid)
else
    HWID=$(hexdump -n 16 -e '4/4 "%08x" 1 "\n"' /dev/urandom | sed 's/\(........\)\(........\)\(........\)\(........\)/\1-\2-\3-\4/')
fi

log "Сгенерирован x-hwid: $HWID"

mkdir -p /opt/clash

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
    'rule-set:direct-domains':
      - https://common.dot.dns.yandex.net/dns-query
    '+.ru,+.su,+.xn--p1ai,+.moscow,+.xn--80adxhks,+.tatar':
      - https://common.dot.dns.yandex.net/dns-query

# --- ПРОВАЙДЕРЫ ПРАВИЛ ---
rule-providers:
  direct-domains:
    type: http
    behavior: domain
    format: mrs
    url: "https://raw.githubusercontent.com/mrslaveg/mihomo-rule-sets/main/rules/direct-domains.mrs"
    path: ./rules/direct-domains.mrs
    interval: 3600

  direct-ip:
    type: http
    behavior: ipcidr
    format: mrs
    url: "https://raw.githubusercontent.com/mrslaveg/mihomo-rule-sets/main/rules/direct-ip.mrs"
    path: ./rules/direct-ip.mrs
    interval: 3600

  proxy-domains:
    type: http
    behavior: domain
    format: mrs
    url: "https://raw.githubusercontent.com/mrslaveg/mihomo-rule-sets/main/rules/proxy-domains.mrs"
    path: ./rules/proxy-domains.mrs
    interval: 3600

  proxy-ip:
    type: http
    behavior: ipcidr
    format: mrs
    url: "https://raw.githubusercontent.com/mrslaveg/mihomo-rule-sets/main/rules/proxy-ip.mrs"
    path: ./rules/proxy-ip.mrs
    interval: 3600

  geosite-ru:
    type: http
    behavior: domain
    format: mrs
    url: "https://raw.githubusercontent.com/mrslaveg/mihomo-rule-sets/main/rules/geosite-ru.mrs"
    path: ./rules/geosite-ru.mrs
    interval: 86400

  geoip-ru:
    type: http
    behavior: ipcidr
    format: mrs
    url: "https://raw.githubusercontent.com/mrslaveg/mihomo-rule-sets/main/rules/geoip-ru.mrs"
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
  # Основная группа для обычной работы
  - name: VPN
    type: select
    proxies:
      - PROXY AUTO
      - PROXY MANUAL
      - DIRECT

  # Автоматический режим:
  # сначала пытаемся работать через PROXY BEST,
  # если весь пул FastConnect недоступен — DIRECT
  - name: PROXY AUTO
    type: fallback
    proxies:
      - PROXY BEST
      - DIRECT
    url: https://cp.cloudflare.com
    interval: 60
    lazy: false

  # Автоматически выбирает наиболее быстрый доступный
  # FastConnect-сервер
  - name: PROXY BEST
    type: url-test
    use:
      - FastConnect
    url: https://cp.cloudflare.com
    interval: 60
    tolerance: 50
    lazy: false

  # Ручной выбор конкретной FastConnect-ноды
  - name: PROXY MANUAL
    type: select
    use:
      - FastConnect

  # Скрытая группа для использования в правилах
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
  # 1. Локальные / приватные сети
  - IP-CIDR,10.0.0.0/8,DIRECT,no-resolve
  - IP-CIDR,172.16.0.0/12,DIRECT,no-resolve
  - IP-CIDR,192.168.0.0/16,DIRECT,no-resolve
  - IP-CIDR,127.0.0.0/8,DIRECT,no-resolve
  - IP-CIDR,100.64.0.0/10,DIRECT,no-resolve
  - IP-CIDR,169.254.0.0/16,DIRECT,no-resolve

  # 2. Эти сервисы принудительно в Direct
  - RULE-SET,direct-domains,DIRECT
  - RULE-SET,direct-ip,DIRECT,no-resolve

  # 3. Россия — домены и IP
  - RULE-SET,geosite-ru,DIRECT
  - RULE-SET,geoip-ru,DIRECT,no-resolve

  # 4. UDP/443 (QUIC) режем
  - AND,((NETWORK,UDP),(DST-PORT,443)),REJECT-DROP

  # 5. Эти сервисы принудительно через VPN
  - RULE-SET,proxy-domains,VPN
  - RULE-SET,proxy-ip,VPN,no-resolve

  # 6. Торрент-порты
  - DST-PORT,6881-6889,DIRECT
  - DST-PORT,51413,DIRECT

  # 7. Всё остальное — VPN
  - MATCH,VPN

EOF

log "Конфиг записан в /opt/clash/config.yaml"

# --------------------------------------------
# 6. Правка /etc/init.d/clash (если есть)
# --------------------------------------------
log "Исправление DNS-порта в /etc/init.d/clash..."

if [ -f /etc/init.d/clash ]; then
    sed -i 's/127\.0\.0\.1#7874/127.0.0.1#753/g' /etc/init.d/clash
    log "DNS-порт изменён на 753"
else
    warn "Файл /etc/init.d/clash не найден (будет использован порт из config.yaml)"
fi

# --------------------------------------------
# 7. DNS Override (53 → 753)
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
# 8. NTP-серверы
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
# 9. Проброс порта 7777 → LAN_IP:80
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
# 10. Включение Wi-Fi
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
# 11. Применение сети + запуск SSClash
# --------------------------------------------
log "Применение сетевых изменений..."
/etc/init.d/network reload 2>/dev/null || /etc/init.d/network restart 2>/dev/null || true

log "Запуск SSClash..."
if [ -f /etc/init.d/clash ]; then
    /etc/init.d/clash enable 2>/dev/null || true
    /etc/init.d/clash restart 2>/dev/null || true
    log "SSClash запущен и добавлен в автозагрузку"
else
    warn "Сервис clash не найден — запусти вручную через LuCI"
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
echo "  • Русский язык установлен"
echo "  • Пароль администратора установлен"
echo "  • IPv6 отключён"
echo "  • SSClash установлен"
echo "  • Дефолтный config.yaml перезаписан"
echo "  • DNS 53 → 753"
echo "  • NTP-серверы установлены"
echo "  • Порт 7777 → $LAN_IP:80"
echo "  • Wi-Fi включён"
echo "  • SSClash запущен"
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
        rm -f /tmp/setup-openwrt.sh 2>/dev/null || true
        sleep 1
        reboot
        ;;
    *)
        info "Перезагрузка отложена"
        rm -f /tmp/setup-openwrt.sh 2>/dev/null || true
        log "Скрипт удалён из /tmp"
        ;;
esac

echo
