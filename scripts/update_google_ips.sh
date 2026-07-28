#!/bin/sh

OUTPUT_FILE="/etc/nginx/google_ips.conf"
TMP_FILE="${OUTPUT_FILE}.tmp"

# URL с официальными IP системных сервисов Google (включая Google Assistant)
GOOGLE_JSON_URL="https://www.gstatic.com/ipranges/goog.json"

# Скачиваем JSON во временный буфер
RAW_JSON=$(curl -s "${GOOGLE_JSON_URL}")

# Проверяем, что ответ не пустой
if [ -z "${RAW_JSON}" ]; then
    echo "ERROR: Failed to fetch Google IPs from ${GOOGLE_JSON_URL}. Exiting."
    exit 1
fi

{
    echo "# Google Official Services IP ranges - generated on $(date)"
    echo "# Source: ${GOOGLE_JSON_URL}"
    echo ""

    # Извлекаем IPv4 префиксы
    echo "${RAW_JSON}" | grep -o '"ipv4Prefix": "[^"]*"' | cut -d'"' -f4 | while read -r ip; do
        [ -n "$ip" ] && echo "${ip} 1;"
    done

    echo ""

    # Извлекаем IPv6 префиксы
    echo "${RAW_JSON}" | grep -o '"ipv6Prefix": "[^"]*"' | cut -d'"' -f4 | while read -r ip; do
        [ -n "$ip" ] && echo "${ip} 1;"
    done
} > "${TMP_FILE}"

# Проверяем, что получился валидный файл с записями
if [ ! -s "${TMP_FILE}" ] || ! grep -q ";" "${TMP_FILE}"; then
    echo "ERROR: Output file is empty or parsing failed. Exiting."
    rm -f "${TMP_FILE}"
    exit 1
fi

# Если IP не изменились — выходим
if [ -f "${OUTPUT_FILE}" ] && cmp -s "${TMP_FILE}" "${OUTPUT_FILE}"; then
    echo "No changes in Google IP ranges. Exiting."
    rm -f "${TMP_FILE}"
    exit 0
fi

echo "Google IP ranges have changed. Updating configuration..."
mv "${TMP_FILE}" "${OUTPUT_FILE}"

# Валидация и перезагрузка Nginx
if nginx -t >/dev/null 2>&1; then
    echo "Nginx configuration is valid. Reloading Nginx..."
    nginx -s reload
    echo "Nginx reloaded successfully."
else
    echo "ERROR: Nginx configuration is invalid."
    exit 1
fi
