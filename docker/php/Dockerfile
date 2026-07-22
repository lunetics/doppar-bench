# Shared PHP-FPM image used identically by all three frameworks.
# Only the mounted application code differs between stacks — the runtime,
# extensions, OPcache and php-fpm pool settings are byte-identical.
FROM php:8.5-fpm-alpine

# mlocati's installer resolves the correct extension versions/deps for this
# exact PHP build (more robust than hand-rolled docker-php-ext-install chains).
COPY --from=mlocati/php-extension-installer /usr/bin/install-php-extensions /usr/bin/

RUN install-php-extensions \
        opcache \
        pdo_sqlite \
        mbstring \
        intl \
        zip \
        bcmath \
        pcntl

# Composer, pinned to the v2 line, for in-container project scaffolding.
COPY --from=composer:2 /usr/bin/composer /usr/bin/composer

# Identical OPcache + pool config for every framework (fairness invariant).
COPY opcache.ini /usr/local/etc/php/conf.d/zz-bench-opcache.ini
COPY www.conf   /usr/local/etc/php-fpm.d/zz-bench-www.conf

RUN apk add --no-cache git

WORKDIR /var/www/html
