FROM debian:bookworm-20241223-slim

# Установка базовых пакетов + cron + ca-certificates + gettext (для envsubst)
RUN apt-get update && apt-get install -y \
    curl gnupg2 ca-certificates lsb-release debian-archive-keyring \
    supervisor php8.2-fpm php8.2-cli php8.2-common php8.2-opcache php8.2-curl \
    cron gettext \
    && apt-get clean

# Установка Nginx из официального репозитория
RUN curl https://nginx.org/keys/nginx_signing.key | gpg --dearmor \
    | tee /usr/share/keyrings/nginx-archive-keyring.gpg >/dev/null \
    && echo "deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] \
    http://nginx.org/packages/debian bookworm nginx" \
    | tee /etc/apt/sources.list.d/nginx.list

RUN apt-get update && apt-get install -y nginx=1.30.0-1~bookworm && apt-get clean

# Установка дополнительных пакетов для системы бана (logrotate, bash)
RUN apt-get update && apt-get install -y \
    logrotate \
    bash \
    && apt-get clean

# Обновление CA-сертификатов
RUN update-ca-certificates --fresh

# Создание директорий
RUN mkdir -p /var/www/html /etc/ssl/certs /etc/ssl/private \
    && chown -R www-data:www-data /var/www/html \
    && mkdir -p /var/log/nginx /var/log/supervisor

# Создание самоподписанного сертификата (запасной вариант)
RUN openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
    -keyout /etc/ssl/private/nginx-selfsigned.key \
    -out /etc/ssl/certs/nginx-selfsigned.crt \
    -subj "/C=RU/ST=Moscow/L=Moscow/O=Default/CN=localhost"

# Настройка PHP-FPM на прослушивание порта 9000
RUN sed -i 's|listen = /run/php/php8.2-fpm.sock|listen = 127.0.0.1:9000|' /etc/php/8.2/fpm/pool.d/www.conf

# ========== СКРИПТ ОБНОВЛЕНИЯ CLOUDFLARE IP ==========
COPY config/update-cloudflare-ips.sh /usr/local/bin/update-cloudflare-ips.sh
RUN chmod +x /usr/local/bin/update-cloudflare-ips.sh

# Создаём начальные файлы с IP Cloudflare (сразу при сборке)
# Этот скрипт создаёт:
#   - /etc/nginx/cloudflare_real_ips.conf (для nginx)
#   - /tmp/cloudflare_ips.txt (для analyze_logs.sh)
RUN /usr/local/bin/update-cloudflare-ips.sh

# ========== СКРИПТ АНАЛИЗА ЛОГОВ И БАНА ==========
COPY scripts/analyze_logs.sh /usr/local/bin/analyze_logs.sh
RUN chmod +x /usr/local/bin/analyze_logs.sh

# Создаём файлы состояния для инкрементального анализа
RUN touch /tmp/nginx_ban_last_run && chmod 666 /tmp/nginx_ban_last_run

# ========== НАСТРОЙКА LOGROTATE ДЛЯ NGINX ==========
COPY config/logrotate-nginx.conf /etc/logrotate.d/nginx

# ========== CRON ДЛЯ CLOUDFLARE (ежедневное обновление) ==========
COPY config/crontab /etc/cron.d/cloudflare-update
RUN chmod 644 /etc/cron.d/cloudflare-update
RUN touch /var/log/cloudflare-update.log && chmod 666 /var/log/cloudflare-update.log

# ========== КОПИРОВАНИЕ КОНФИГОВ ==========
COPY config/nginx.conf.template /etc/nginx/nginx.conf.template
COPY config/supervisord.conf /etc/supervisor/supervisord.conf
COPY config/default-site.conf /etc/nginx/conf.d/default.conf
COPY config/php-fpm.conf /etc/php/8.2/fpm/pool.d/www.conf

# ========== ENTRYPOINT ==========
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Рабочая директория
WORKDIR /var/www/html

EXPOSE 80 443 8443

ENTRYPOINT ["/entrypoint.sh"]
