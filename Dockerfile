# Используем Debian как основу, чтобы избежать проблем с совместимостью
FROM debian:bookworm-slim

# Устанавливаем необходимые зависимости для сборки и работы
RUN apt-get update && apt-get install -y \
    curl \
    gnupg2 \
    ca-certificates \
    lsb-release \
    debian-archive-keyring \
    supervisor \
    php8.2-fpm \
    php8.2-cli \
    php8.2-common \
    && apt-get clean

# Устанавливаем официальный Nginx из репозитория Nginx, чтобы получить версию с поддержкой stream_ssl_preread_module
RUN curl https://nginx.org/keys/nginx_signing.key | gpg --dearmor \
    | tee /usr/share/keyrings/nginx-archive-keyring.gpg >/dev/null \
    && echo "deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] \
    http://nginx.org/packages/debian $(lsb_release -cs) nginx" \
    | tee /etc/apt/sources.list.d/nginx.list

# Устанавливаем Nginx
RUN apt-get update && apt-get install -y nginx && apt-get clean

# Проверяем, что модуль stream_ssl_preread_module установлен
RUN nginx -V 2>&1 | grep -o with-stream_ssl_preread_module

# Копируем наши конфигурационные файлы
COPY config/nginx.conf /etc/nginx/nginx.conf
COPY config/supervisord.conf /etc/supervisor/conf.d/supervisord.conf
COPY config/php-fpm.conf /etc/php/8.2/fpm/pool.d/www.conf

# Создаем директорию для сайта
RUN mkdir -p /var/www/html && chown -R www-data:www-data /var/www/html

EXPOSE 80 443

# Запускаем supervisor для управления процессами
CMD ["/usr/bin/supervisord", "-n", "-c", "/etc/supervisor/supervisord.conf"]
