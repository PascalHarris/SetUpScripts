# Save this as php-fpm/Dockerfile (referenced by "build: ./php-fpm" in
# docker-compose.yml).
#
# Extends the official php-fpm image with the extensions WordPress needs
# and wp-cli, so the whole image is rebuilt reproducibly from this one
# file rather than hand-installed with ad-hoc `docker exec` commands on a
# running container (which is what the old wp-cli/lego host-fetch dance
# was quietly working around elsewhere in the old scripts).
FROM php:8.3-fpm-alpine

RUN apk add --no-cache \
        curl \
        libzip-dev \
        freetype-dev \
        libjpeg-turbo-dev \
        libpng-dev \
        icu-dev \
    && docker-php-ext-configure gd --with-freetype --with-jpeg \
    && docker-php-ext-install -j"$(nproc)" \
        mysqli \
        gd \
        zip \
        intl \
        opcache \
    && curl -fsSL https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar -o /usr/local/bin/wp \
    && chmod +x /usr/local/bin/wp

WORKDIR /var/www/html
