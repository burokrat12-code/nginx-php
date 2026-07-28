#!/bin/sh

OUTPUT_FILE="/etc/nginx/cloudflare_real_ips.conf"
CF_FILTER_FILE="/tmp/cloudflare_ips.txt"
TMP_FILE="${OUTPUT_FILE}.tmp"
TMP_CF_FILE="${CF_FILTER_FILE}.tmp"
RELOAD_NGINX="${1:-false}"

# 1. Файл для nginx
{
    echo "# Cloudflare IP ranges - generated on $(date)"
    echo ""
    curl -s https://www.cloudflare.com/ips-v4 | while read ip; do
        [ -n "$ip" ] && echo "set_real_ip_from ${ip};"
    done
    echo ""
    curl -s https://www.cloudflare.com/ips-v6 | while read ip; do
        [ -n "$ip" ] && echo "set_real_ip_from ${ip};"
    done
    echo ""
    echo "real_ip_header CF-Connecting-IP;"
} > ${TMP_FILE}

if [ -f ${OUTPUT_FILE} ] && cmp -s ${TMP_FILE} ${OUTPUT_FILE}; then
    rm -f ${TMP_FILE}
else
    mv ${TMP_FILE} ${OUTPUT_FILE}
fi

# 2. Файл для скрипта бана
{
    curl -s https://www.cloudflare.com/ips-v4 2>/dev/null
    echo ""
    curl -s https://www.cloudflare.com/ips-v6 2>/dev/null
} > ${TMP_CF_FILE}

if [ -f ${CF_FILTER_FILE} ] && cmp -s ${TMP_CF_FILE} ${CF_FILTER_FILE}; then
    rm -f ${TMP_CF_FILE}
else
    mv ${TMP_CF_FILE} ${CF_FILTER_FILE}
fi

# 3. Перезагрузка nginx
if [ "$RELOAD_NGINX" = "reload" ] && pgrep nginx > /dev/null; then
    nginx -t >/dev/null 2>&1 && nginx -s reload
fi
