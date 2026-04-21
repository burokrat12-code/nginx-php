#!/bin/sh

envsubst '${MAIN_DOMAIN} ${PUSH_DOMAIN} ${MAIL_DOMAIN} ${WEB_ROOT} ${NTFY_BACKEND} ${NTFY_UserAgent} ${NTFY_SECRET_PATH} ${MAIL_BACKEND} ${MAIL_SECRET_PATH}' \
    < /etc/nginx/nginx.conf.template \
    > /etc/nginx/nginx.conf

exec /usr/bin/supervisord -n -c /etc/supervisor/supervisord.conf
