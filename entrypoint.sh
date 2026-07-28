#!/bin/sh

# 1. Экранируем точки в IP для использования в регулярных выражениях
export IP_SERV_ESCAPED=$(echo "${IP_SERV}" | sed 's/\./\\./g')

# 2. Подставляем переменные окружения в шаблон конфига Nginx
envsubst '${MAIN_DOMAIN} ${PUSH_DOMAIN} ${MAIL_DOMAIN} ${HA_DOMAIN} ${HA_BACKEND} ${X_TOKEN} ${WEB_ROOT} ${NTFY_BACKEND} ${NTFY_UserAgent} ${NTFY_SECRET_PATH} ${MAIL_BACKEND} ${MAIL_SECRET_PATH} ${HAPROXY_IP} ${IP_SERV_ESCAPED} ${VLESS_DOMAIN} ${VLESS_BACKEND} ${VLESS_XHTTP_DOMAIN}' \
    < /etc/nginx/nginx.conf.template \
    > /etc/nginx/nginx.conf

# 3. Гарантируем наличие включемых файлов IP, чтобы Nginx не упал при старте, если сети еще нет
touch /etc/nginx/cloudflare_real_ips.conf
touch /etc/nginx/my_custom_ips.conf
touch /etc/nginx/google_ips.conf

# 4. Выполняем первичный прогон скриптов обновления IP (без перезагрузки Nginx)
[ -x /usr/local/bin/update-cloudflare-ips.sh ] && /usr/local/bin/update-cloudflare-ips.sh
[ -x /usr/local/bin/update_my_ips.sh ] && /usr/local/bin/update_my_ips.sh
[ -x /usr/local/bin/update_google_ips.sh ] && /usr/local/bin/update_google_ips.sh

# 5. Запускаем Supervisor
exec /usr/bin/supervisord -n -c /etc/supervisor/supervisord.conf
