FROM debian:bookworm-20241223-slim

RUN apt-get update && apt-get install -y \
    curl gnupg2 ca-certificates lsb-release debian-archive-keyring \
    supervisor php8.2-fpm php8.2-cli php8.2-common php8.2-opcache openssl \
    cron \
    && apt-get clean

RUN curl https://nginx.org/keys/nginx_signing.key | gpg --dearmor \
    | tee /usr/share/keyrings/nginx-archive-keyring.gpg >/dev/null \
    && echo "deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] \
    http://nginx.org/packages/debian bookworm nginx" \
    | tee /etc/apt/sources.list.d/nginx.list

RUN apt-get update && apt-get install -y nginx=1.30.0-1~bookworm && apt-get clean

RUN update-ca-certificates --fresh

RUN mkdir -p /var/www/html /etc/ssl/certs /etc/ssl/private \
    && chown -R www-data:www-data /var/www/html \
    && mkdir -p /var/log/nginx /var/log/supervisor

RUN openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
    -keyout /etc/ssl/private/nginx-selfsigned.key \
    -out /etc/ssl/certs/nginx-selfsigned.crt \
    -subj "/C=RU/ST=Moscow/L=Moscow/O=Default/CN=localhost"

RUN sed -i 's|listen = /run/php/php8.2-fpm.sock|listen = 127.0.0.1:9000|' /etc/php/8.2/fpm/pool.d/www.conf

COPY config/update-cloudflare-ips.sh /usr/local/bin/update-cloudflare-ips.sh
RUN chmod +x /usr/local/bin/update-cloudflare-ips.sh
RUN /usr/local/bin/update-cloudflare-ips.sh   # ← БЕЗ reload (Nginx не запущен)

COPY config/crontab /etc/crontab
RUN chmod 644 /etc/crontab && crontab /etc/crontab
RUN touch /var/log/cloudflare-update.log && chmod 666 /var/log/cloudflare-update.log

COPY config/nginx.conf /etc/nginx/nginx.conf
COPY config/supervisord.conf /etc/supervisor/supervisord.conf
COPY config/default-site.conf /etc/nginx/conf.d/default.conf
COPY config/php-fpm.conf /etc/php/8.2/fpm/pool.d/www.conf

WORKDIR /var/www/html

EXPOSE 80 443 8443

CMD ["/usr/bin/supervisord", "-n", "-c", "/etc/supervisor/supervisord.conf"]
