#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

fail() { printf 'Ошибка: %s\n' "$*" >&2; exit 1; }

if [[ ${1:-} == --help ]]; then
    printf '%s\n' 'sudo bash install-yandex-cdn.sh' 'Чистый Ubuntu 24.04 LTS. Домены, адрес панели, email и ключ вводятся интерактивно.'
    exit 0
fi
[[ $# == 0 ]] || fail 'Использование: bash install-yandex-cdn.sh'
[[ $EUID == 0 ]] || fail 'Запусти скрипт от root.'
[[ -t 0 ]] || fail 'Запусти скачанный файл в интерактивной SSH-сессии.'
. /etc/os-release
[[ $ID == ubuntu && $VERSION_ID == 24.04 ]] || fail 'Поддерживается Ubuntu 24.04 LTS.'
STATE=/var/lib/remnawave-cdn-installer
exec 9>/run/lock/remnawave-cdn-installer.lock
flock -n 9 || fail 'Установка уже выполняется.'
if [[ ! -f $STATE/domains ]]; then
    for path in /opt/cdn-nginx /opt/remnanode /etc/mobile-filter; do
        [[ ! -e $path ]] || fail "$path уже существует. Используй чистый сервер."
    done
    [[ -z $(ss -H -ltn '( sport = :80 or sport = :443 or sport = :2222 or sport = :4443 )') ]] ||
        fail 'Один из портов 80, 443, 2222 или 4443 уже занят.'
fi

printf '%s\n' \
  'До установки создай A-запись домена источника на публичный IPv4 этого VPS.' \
  'В Remnawave открой Ноды → Ноды → +. Укажи домен источника и Node Port 2222.' \
  'В карточке скопируй SECRET_KEY из Docker Compose. Он понадобится ниже.'
read -r -p 'Домен источника (A-запись на VPS): ' DOMAIN
read -r -p 'Клиентский домен Yandex CDN: ' CDN_DOMAIN
read -r -p 'Публичный IPv4, с которого панель Remnawave обращается к ноде: ' PANEL_IP
read -r -p "Email для Let's Encrypt: " ACME_EMAIL
read -r -s -p 'SECRET_KEY ноды из панели: ' NODE_SECRET
printf '\n'
for domain in "$DOMAIN" "$CDN_DOMAIN"; do
    [[ ${#domain} -le 253 && $domain =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]] ||
        fail "Недопустимое доменное имя: $domain"
done
DOMAIN=${DOMAIN,,}
CDN_DOMAIN=${CDN_DOMAIN,,}
[[ $DOMAIN != "$CDN_DOMAIN" ]] || fail 'Нужны два разных домена.'
[[ $ACME_EMAIL =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]] || fail 'Некорректный email.'
[[ $NODE_SECRET =~ ^[A-Za-z0-9_./+=-]{40,}$ ]] || fail 'Скопируй только значение SECRET_KEY из Docker Compose.'
[[ -n ${SSH_CONNECTION:-} ]] || fail 'Для настройки UFW запусти скрипт из SSH-сессии root.'
read -r _ _ _ SSH_PORT <<< "$SSH_CONNECTION"
[[ $SSH_PORT =~ ^[0-9]+$ ]] || fail 'Не удалось определить SSH-порт.'

if [[ -f $STATE/domains ]] && [[ $(cat "$STATE/domains") != "$DOMAIN $CDN_DOMAIN" ]]; then
    fail 'Повторный запуск допустим только с теми же двумя доменами.'
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y ca-certificates certbot curl python3 dnsutils ufw cron
python3 - "$PANEL_IP" <<'PYIP'
import ipaddress
import sys

if not ipaddress.IPv4Address(sys.argv[1]).is_global:
    raise SystemExit("Нужен публичный IPv4 панели")
PYIP
[[ $(dig +short A "$DOMAIN" | awk '/^[0-9.]+$/ {print}' | sort -u | wc -l) == 1 ]] ||
    fail "У $DOMAIN должна быть одна A-запись на IPv4 этого VPS."
[[ -z $(dig +short AAAA "$DOMAIN") ]] || fail "Для этой конфигурации убери AAAA-запись $DOMAIN."
install -d -m 700 "$STATE"
printf '%s %s\n' "$DOMAIN" "$CDN_DOMAIN" > "$STATE/domains"

# Docker: если уже установлен (docker-ce или docker.io) — не трогаем,
# иначе пакеты конфликтуют и apt сносит существующий Docker
if dpkg -s docker-ce >/dev/null 2>&1; then
    echo "Docker CE уже установлен ✓"
    docker compose version >/dev/null 2>&1 || apt install -y docker-compose-plugin || fail "docker-compose-plugin"
elif dpkg -s docker.io >/dev/null 2>&1; then
    echo "docker.io уже установлен ✓"
    docker compose version >/dev/null 2>&1 || apt install -y docker-compose-v2 || fail "docker-compose-v2"
else
    apt install -y docker.io docker-compose-v2 || fail "установка docker"
fi
systemctl enable docker && systemctl start docker
docker compose version || fail "docker compose не работает"

if [ ! -f /etc/letsencrypt/live/$DOMAIN/fullchain.pem ]; then
    certbot certonly --standalone -d "$DOMAIN" --non-interactive --agree-tos -m "$ACME_EMAIL" || fail "certbot"
fi
ls "/etc/letsencrypt/live/$DOMAIN/"

# Автопродление сертификата: certbot standalone нужен порт 80,
# поэтому на время продления останавливаем контейнер
mkdir -p /etc/letsencrypt/renewal-hooks/pre /etc/letsencrypt/renewal-hooks/post
printf '#!/bin/sh\ndocker stop cdn-nginx\n'  > /etc/letsencrypt/renewal-hooks/pre/stop-cdn-nginx.sh
printf '#!/bin/sh\ndocker start cdn-nginx\n' > /etc/letsencrypt/renewal-hooks/post/start-cdn-nginx.sh
chmod 755 /etc/letsencrypt/renewal-hooks/pre/stop-cdn-nginx.sh /etc/letsencrypt/renewal-hooks/post/start-cdn-nginx.sh

mkdir -p /opt/cdn-nginx/html /opt/cdn-nginx/mobile-filter
cd /opt/cdn-nginx || fail "не удалось открыть /opt/cdn-nginx"

# ============================================================
# MOBILE FILTER: списки ASN и IP
# ============================================================

mkdir -p /etc/mobile-filter
touch /etc/mobile-filter/custom-asns.conf /etc/mobile-filter/custom-ips.conf

# Встроенные мобильные ASN (AS12389 Ростелеком специально не включён)
cat > /etc/mobile-filter/base-asns.conf <<'EOF'
8359
3216
16345
42842
31133
47395
35298
31224
31213
31208
31205
31195
31163
25159
12958
15378
42437
48092
48190
41330
39374
201776
206673
35816
205638
214257
202498
203451
203561
47204
31499
214721
204108
59833
47203
EOF

# Точечные сети (мобильный Ростелеком и др.)
cat > /etc/mobile-filter/static-ips.conf <<'EOF'
5.141.100.0/22
5.141.192.0/22
5.142.40.0/21
83.219.13.0/24
87.226.172.0/24
87.226.203.0/24
87.226.204.0/23
87.226.206.0/24
87.226.209.0/24
87.226.210.0/23
87.226.212.0/24
87.226.218.0/24
88.205.192.0/20
89.20.97.0/24
89.20.102.0/24
89.204.112.0/20
95.86.213.0/24
95.86.214.0/23
95.152.44.0/24
95.152.62.0/24
95.167.104.0/24
176.119.160.0/21
176.119.168.0/24
176.119.173.0/24
176.119.174.0/23
178.47.161.0/24
178.67.192.0/21
188.254.122.0/23
195.38.60.0/22
212.120.169.0/24
213.24.147.0/24
217.107.106.0/24
5.101.18.0/24
91.107.97.0/24
84.18.108.0/24
EOF

# ============================================================
# MOBILE FILTER: скрипт обновления диапазонов
# ============================================================

cat > /usr/local/bin/update-mobile-ranges.sh <<'UPDATER'
#!/usr/bin/env bash
# update-mobile-ranges.sh          — обновить диапазоны и перезагрузить nginx
# update-mobile-ranges.sh --force  — без защиты от резкого уменьшения списка
# update-mobile-ranges.sh --build  — только собрать список (первая установка)
set -uo pipefail
umask 022

BASE="/etc/mobile-filter"
RANGES="/opt/cdn-nginx/mobile-filter/ranges.conf"
CONTAINER="cdn-nginx"
MIN_PERCENT=50

FORCE=0
BUILD_ONLY=0
case "${1:-}" in
    --force) FORCE=1 ;;
    --build) BUILD_ONLY=1 ;;
    "") ;;
    *) echo "Usage: $0 [--force | --build]"; exit 1 ;;
esac

echo "=== $(date '+%Y-%m-%d %H:%M:%S') ==="

TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT
FAILED=0

ASNS="$(cat "$BASE/base-asns.conf" "$BASE/custom-asns.conf" 2>/dev/null |
        tr -d ' \t\r' | sed 's/^[Aa][Ss]//' | grep -E '^[0-9]+$' | sort -nu)"

for A in $ASNS; do
    printf '  AS%s ... ' "$A"
    if OUT="$(curl -fsS --retry 3 --retry-delay 2 --max-time 30 \
            "https://stat.ripe.net/data/announced-prefixes/data.json?resource=AS${A}" |
        python3 -c '
import json, sys
for item in json.load(sys.stdin).get("data", {}).get("prefixes", []):
    p = item.get("prefix", "").strip()
    if p and ":" not in p:
        print(p)
')"; then
        if [[ -n "$OUT" ]]; then
            printf '%s\n' "$OUT" >> "$TMP"
            echo "$(printf '%s\n' "$OUT" | wc -l) prefixes"
        else
            echo "0 prefixes"
        fi
    else
        echo "ERROR"
        FAILED=$((FAILED + 1))
    fi
    sleep 0.12
done

# Статические и свои IP/CIDR (строки с # и пустые пропускаются)
cat "$BASE/static-ips.conf" "$BASE/custom-ips.conf" 2>/dev/null |
    sed 's/#.*//' | tr -d ' \t\r' | grep -v '^$' >> "$TMP"

# Формат для nginx geo: "1.2.3.0/24 1;"
sed -i '/^$/d; s/$/ 1;/' "$TMP"
sort -u "$TMP" -o "$TMP"

NEW="$(wc -l < "$TMP")"
echo "Итого IPv4 prefixes: ${NEW}"
if (( FAILED > 0 )); then
    echo "ERROR: не удалось получить ${FAILED} ASN, текущий список сохранён."
    exit 1
fi

if (( NEW == 0 )); then
    echo "ERROR: список пуст. Старый список оставлен."
    exit 1
fi

if (( BUILD_ONLY == 1 )); then
    install -m 644 "$TMP" "$RANGES"
    exit $?
fi

OLD="$( { cat "$RANGES" 2>/dev/null || true; } | wc -l )"

if (( FORCE == 0 && OLD > 0 && NEW * 100 < OLD * MIN_PERCENT )); then
    echo "ERROR: новый список (${NEW}) меньше ${MIN_PERCENT}% старого (${OLD})."
    echo "Вероятно, RIPE недоступен. Старый список оставлен. Принудительно: $0 --force"
    exit 1
fi

cp -f "$RANGES" "${RANGES}.prev" || exit 1
NEXT="$(mktemp "${RANGES}.XXXXXX")" || exit 1
install -m 644 "$TMP" "$NEXT" && mv -f "$NEXT" "$RANGES" || exit 1

if ! docker exec "$CONTAINER" nginx -t; then
    echo "ERROR: nginx -t failed, восстанавливаю прежний список."
    [[ -f "${RANGES}.prev" ]] && cat "${RANGES}.prev" > "$RANGES"
    exit 1
fi

docker exec "$CONTAINER" nginx -s reload || exit 1
echo "Updated: ${NEW} IPv4 prefixes (было ${OLD})."
UPDATER
chmod 755 /usr/local/bin/update-mobile-ranges.sh

echo "Сборка списка мобильных диапазонов..."
if [[ ! -s /opt/cdn-nginx/mobile-filter/ranges.conf ]]; then
    /usr/local/bin/update-mobile-ranges.sh --build || fail "не удалось собрать список мобильных IP. Повтори запуск с теми же доменами."
fi

# Обновление каждый день в 02:00
cat > /etc/cron.d/mobile-filter <<'EOF'
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
0 2 * * * root /usr/local/bin/update-mobile-ranges.sh >> /var/log/mobile-filter-update.log 2>&1
EOF
chmod 644 /etc/cron.d/mobile-filter

# ============================================================
# MOBILE FILTER: переменная $mobile_allowed (контекст http)
# ============================================================

cat > mobile-filter.conf <<'EOF'
map $http_x_forwarded_for $mobile_client_ip {
    default $remote_addr;
    "~^(?<mobile_first_ip>[^, ]+)" $mobile_first_ip;
}

geo $mobile_client_ip $mobile_allowed {
    default 0;
    include /etc/nginx/mobile-filter/ranges.conf;
}
EOF
# ============================================================
# DOCKER + NGINX
# ============================================================

cat > docker-compose.yml <<EOF
services:
  cdn-nginx:
    image: nginx:1.28
    container_name: cdn-nginx
    restart: always
    network_mode: host
    volumes:
      - ./nginx.conf:/etc/nginx/conf.d/default.conf:ro
      - ./mobile-filter.conf:/etc/nginx/conf.d/00-mobile-filter.conf:ro
      - ./mobile-filter:/etc/nginx/mobile-filter:ro
      - /etc/letsencrypt:/etc/letsencrypt:ro
      - ./html:/usr/share/nginx/html:ro
EOF

cat > nginx.conf <<EOF
server {
    listen 80;
    server_name $DOMAIN;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl;
    http2 on;
    server_name $DOMAIN;

    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;

    location /api/uploadFile/ {
        # MOBILE FILTER: не мобильный IP — 403
        if (\$mobile_allowed = 0) {
            return 403;
        }

        proxy_pass http://127.0.0.1:4443;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;

        add_header Cache-Control "no-store, no-cache, must-revalidate, proxy-revalidate" always;
        add_header Pragma "no-cache" always;
        add_header Expires "0" always;

        proxy_buffering off;
        proxy_request_buffering off;
        proxy_cache off;

        proxy_connect_timeout 60s;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;

        client_max_body_size 0;
    }

    location / {
        root /usr/share/nginx/html;
        index index.html;
        add_header Cache-Control "public, max-age=86400" always;
    }
}
EOF

cat > html/index.html <<'EOF'
ok
EOF


chmod 755 /opt/cdn-nginx/html
chmod 644 /opt/cdn-nginx/html/index.html
docker compose config --quiet
docker compose run --rm --no-deps cdn-nginx nginx -t
docker compose up -d --force-recreate
docker exec cdn-nginx nginx -t
systemctl enable --now cron certbot.timer
curl -fsS --retry 5 --retry-connrefused --max-time 10 \
    --resolve "$DOMAIN:443:127.0.0.1" "https://$DOMAIN/"

# Защита API ноды. Сначала разрешаем SSH на порту текущего подключения.
ufw allow "$SSH_PORT/tcp"
ufw allow 80/tcp
ufw allow 443/tcp
if [[ -f $STATE/panel-ip ]] && [[ $(cat "$STATE/panel-ip") != "$PANEL_IP" ]]; then
    fail "Для повторной установки используй тот же IP панели, который записан в $STATE/panel-ip."
fi
ufw insert 1 allow from "$PANEL_IP" to any port 2222 proto tcp
ufw insert 2 deny 2222/tcp
printf '%s\n' "$PANEL_IP" > "$STATE/panel-ip"
ufw --force enable

install -d -m 700 /opt/remnanode
cat > /opt/remnanode/docker-compose.yml <<EOF
services:
  remnanode:
    image: remnawave/node:latest
    container_name: remnanode
    hostname: remnanode
    network_mode: host
    restart: unless-stopped
    environment:
      NODE_PORT: "2222"
      SECRET_KEY: "$NODE_SECRET"
EOF
unset NODE_SECRET
docker compose -f /opt/remnanode/docker-compose.yml up -d
[[ $(docker inspect -f '{{.State.Running}}' remnanode) == true ]] || fail 'Контейнер remnanode не запущен.'

cat > /opt/remnanode/xray-cdn-profile.json <<'PROFILE'
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "tag": "XHTTP_YANDEX_CDN",
      "listen": "127.0.0.1",
      "port": 4443,
      "protocol": "vless",
      "settings": { "clients": [], "decryption": "none" },
      "sniffing": { "enabled": true, "destOverride": ["http", "tls", "quic"] },
      "streamSettings": {
        "network": "xhttp",
        "security": "none",
        "xhttpSettings": {
          "mode": "packet-up",
          "path": "/api/uploadFile/",
          "noSSEHeader": false,
          "extra": {
            "xmux": {
              "cMaxLifetimeMs": 300000,
              "cMaxReuseTimes": 100,
              "maxConcurrency": "16-32",
              "maxConnections": 0,
              "hKeepAlivePeriod": 30
            },
            "uplinkDataKey": "X-Payload",
            "uplinkHTTPMethod": "GET",
            "uplinkDataPlacement": "header"
          }
        }
      }
    }
  ],
  "outbounds": [
    { "tag": "DIRECT", "protocol": "freedom" },
    { "tag": "BLOCK", "protocol": "blackhole" }
  ],
  "routing": {
    "rules": [
      { "type": "field", "ip": ["geoip:private"], "outboundTag": "BLOCK" },
      { "type": "field", "domain": ["geosite:private"], "outboundTag": "BLOCK" },
      { "type": "field", "protocol": ["bittorrent"], "outboundTag": "BLOCK" }
    ]
  }
}
PROFILE
docker exec -i remnanode xray run -test -config stdin: < /opt/remnanode/xray-cdn-profile.json

cat > /opt/remnanode/xhttp-host-extra.json <<'HOST_EXTRA'
{
  "xmux": {
    "cMaxLifetimeMs": 300000,
    "cMaxReuseTimes": 100,
    "maxConcurrency": "16-32",
    "maxConnections": 0,
    "hKeepAlivePeriod": 30
  },
  "uplinkDataKey": "X-Payload",
  "uplinkHTTPMethod": "GET",
  "uplinkDataPlacement": "header",
  "scMaxEachPostBytes": 4096
}
HOST_EXTRA

cat > /opt/remnanode/NEXT-STEPS.txt <<EOF

Сервер установлен. Дальше настрой Yandex Cloud и Remnawave.

1. Yandex Cloud → Cloud CDN → Группы источников → Создать группу источников.
   Добавь один источник типа «Сервер». Адрес — $DOMAIN, порт HTTPS — 443.
   Назначь его основным.

2. Yandex Cloud → Certificate Manager → Добавить сертификат Let's Encrypt.
   Домен сертификата — $CDN_DOMAIN. Выполни проверку владения доменом
   по DNS-записи из Certificate Manager и дождись статуса «Выпущен».
   Если сертификат для этого домена уже выпущен, выбери его в следующем шаге.

3. Yandex Cloud → Cloud CDN → CDN-ресурсы → Создать ресурс.
   Включи «Доступ к контенту» и выбери «Из группы источников» → группа из шага 1.
   Протокол для источников — HTTPS. Включи «Задать SNI вручную» → $DOMAIN.
   Заголовок Host → «Своё значение» → $DOMAIN.
   Доменное имя ресурса — $CDN_DOMAIN.
   Тип сертификата → «Сертификат из Certificate Manager» → сертификат из шага 2.
   На вкладке «Кеширование» отключи кеширование ресурса или маршрута /api/uploadFile/.
   На вкладке «HTTP-заголовки и методы» убедись, что GET разрешён
   и заголовок X-Payload передаётся источнику.

4. Cloud CDN → CDN-ресурсы → $CDN_DOMAIN → Обзор → Настройки DNS.
   Скопируй адрес *.topology.gslb.yccdn.ru, выданный именно этому ресурсу.
   В панели DNS зоны создай CNAME для $CDN_DOMAIN на этот адрес.
   A-запись $DOMAIN должна указывать напрямую на VPS.
   Проверь: curl -fsS https://$DOMAIN/ и curl -fsS https://$CDN_DOMAIN/
   Оба адреса должны вывести ok.

5. Remnawave → Профили → +. Создай отдельный профиль для новой ноды.
   Вставь в редактор весь JSON из файла /opt/remnanode/xray-cdn-profile.json.
   Сохрани профиль после сообщения Xray config is valid.
   Remnawave → Ноды → Ноды → карточка новой ноды.
   Адрес — $DOMAIN, Node Port — 2222.
   В «Конфигурация ядра» выбери созданный профиль и inbound XHTTP_YANDEX_CDN.
   Сохрани. Дождись, пока нода появится онлайн.
   Проверь на VPS: ss -ltn | grep ':4443'
   Ожидаемый адрес прослушивания — 127.0.0.1:4443.

6. Remnawave → Пользователи → Внутренние сквады.
   В нужном скваде отметь inbound XHTTP_YANDEX_CDN и сохрани.
   Убедись, что тестовый пользователь состоит в этом скваде.

7. Remnawave → Подписка → Хосты → +.
   Выбери профиль из шага 5 и inbound XHTTP_YANDEX_CDN.
   Адрес — $CDN_DOMAIN, порт — 443.
   Опции → Ноды → выбери созданную ноду.
   SNI — $CDN_DOMAIN. Security Layer — TLS. Отпечаток — firefox.
   Host — $CDN_DOMAIN. Путь — /api/uploadFile/. ALPN — h2,http/1.1.
   Доп. параметры XHTTP → вставь JSON из /opt/remnanode/xhttp-host-extra.json.
   Сохрани JSON в окне редактора, затем отдельно сохрани карточку Host.
   Если нужен фиксированный IP CDN, сначала проверь его с именем этого ресурса:
     curl --resolve '$CDN_DOMAIN:443:IP_CDN' https://$CDN_DOMAIN/
   После успешной проверки укажи этот IP только в поле «Адрес».
   SNI и Host должны оставаться $CDN_DOMAIN.

8. Обнови подписку в клиенте. Проверь трафик на мобильном интернете и по Wi-Fi.
   В обычной сети GET /api/uploadFile/ должен получать 403.
   Фильтр использует первый IP из X-Forwarded-For. Для строгого ограничения
   доступа проверь доверие к этому заголовку и прямой доступ к источнику.
   Диапазоны ASN включают IPv4-подсети операторов и могут включать фиксированный доступ.
   IPv6-клиенты в список фильтра не входят.

Диагностика на VPS:
  docker logs --tail 100 remnanode
  docker logs --tail 100 cdn-nginx
  docker exec cdn-nginx nginx -t
  tail -100 /var/log/mobile-filter-update.log
  ufw status numbered

Инструкция сохранена в /opt/remnanode/NEXT-STEPS.txt.
EOF
cat /opt/remnanode/NEXT-STEPS.txt
