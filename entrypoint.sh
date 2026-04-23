#!/bin/sh

# Экранируем точки в IP для использования в регулярных выражениях
# Используем одинарный бэкслеш для правильного экранирования
export IP_SERV_ESCAPED=$(echo "${IP_SERV}" | sed 's/\./\\./g')

envsubst '${MAIN_DOMAIN} ${PUSH_DOMAIN} ${MAIL_DOMAIN} ${WEB_ROOT} ${NTFY_BACKEND} ${NTFY_UserAgent} ${NTFY_SECRET_PATH} ${MAIL_BACKEND} ${MAIL_SECRET_PATH} ${HAPROXY_IP} ${IP_SERV_ESCAPED} ${VLESS_DOMAIN} ${VLESS_BACKEND} ${VLESS_XHTTP_DOMAIN}' \
    < /etc/nginx/nginx.conf.template \
    > /etc/nginx/nginx.conf

exec /usr/bin/supervisord -n -c /etc/supervisor/supervisord.conf
