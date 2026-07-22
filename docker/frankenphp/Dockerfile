# FrankenPHP image shared by ALL worker-group stacks (Doppar custom worker,
# Laravel Octane, Symfony runtime). Matches the FPM image's extension surface
# (pdo_sqlite, opcache, intl, zip, bcmath, pcntl) so the only variables versus
# the FPM stacks are the runtime model and the web server. pcntl is required by
# Laravel Octane (SIGINT/SIGTERM signal handling); the base image already ships
# mbstring, ctype, dom, tokenizer, session, etc.
FROM dunglas/frankenphp:latest
RUN install-php-extensions pdo_sqlite opcache intl zip bcmath pcntl
