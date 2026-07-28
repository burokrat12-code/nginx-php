#!/bin/sh

DOMAINS_FILE="/etc/nginx/my_domains.list"
OUTPUT_FILE="/etc/nginx/my_custom_ips.conf"
TMP_FILE="${OUTPUT_FILE}.tmp"
CACHE_FILE="/var/run/my_resolved_ips.cache"

# Если файл с доменами не существует или пуст — тихо выходим
if [ ! -s "$DOMAINS_FILE" ]; then
    exit 0
fi

# Читаем домены из файла, игнорируя комментарии (#) и пустые строки
MY_DOMAINS=$(grep -v '^[[:space:]]*#' "$DOMAINS_FILE" | grep -v '^[[:space:]]*$' | tr '\n' ' ')

# 1. Резолвим IP-адреса твоих доменов во временный буфер
CURRENT_IPS=""
for domain in $MY_DOMAINS; do
    # Получаем IPv4 адреса (работает в Alpine/BusyBox/Debian)
    ips=$(getent ahostsv4 "$domain" 2>/dev/null | awk '{print $1}' | sort -u)
    if [ -n "$ips" ]; then
        CURRENT_IPS="${CURRENT_IPS} ${ips}"
    fi
done

# Очищаем и сортируем список IP
RESOLVED_IPS=$(echo "$CURRENT_IPS" | tr ' ' '\n' | grep -v '^$' | LC_ALL=C sort -u)

# Если не удалось зарезолвить ни один IP (например, упал DNS или интернет) — тихо выходим
if [ -z "$RESOLVED_IPS" ]; then
    exit 0
fi

# 2. Сравниваем с КЕШЕМ прошлых IP-адресов.
if [ -f "$CACHE_FILE" ]; then
    OLD_IPS=$(cat "$CACHE_FILE")
    if [ "$RESOLVED_IPS" = "$OLD_IPS" ] && [ -f "$OUTPUT_FILE" ]; then
        # IP не менялись — выходим за 1 мс, Nginx не трогаем
        exit 0
    fi
fi

# 3. Если IP изменились — генерируем конфиг для Nginx
{
    echo "# Dynamic My IPs - updated on $(date)"
    echo "$RESOLVED_IPS" | while read -r ip; do
        [ -n "$ip" ] && echo "${ip} 1;"
    done
} > "${TMP_FILE}"

# Проверяем, что файл сгенерировался корректно
if [ ! -s "${TMP_FILE}" ]; then
    rm -f "${TMP_FILE}"
    exit 0
fi

# Перезаписываем итоговый файл конфига и сохраняем новое состояние в кеш
mv "${TMP_FILE}" "${OUTPUT_FILE}"
echo "$RESOLVED_IPS" > "$CACHE_FILE"

# 4. Перезагружаем Nginx только при реальном изменении IP
if nginx -t >/dev/null 2>&1; then
    nginx -s reload
    echo "$(date): IPs changed. Updated Nginx config and reloaded."
fi
