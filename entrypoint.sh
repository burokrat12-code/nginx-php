#!/bin/sh

# Подставляем переменные в шаблон nginx
envsubst < /etc/nginx/nginx.conf.template > /etc/nginx/nginx.conf

# Запускаем supervisord
exec /usr/bin/supervisord -n -c /etc/supervisor/supervisord.conf
