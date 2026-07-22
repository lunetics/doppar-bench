# FrankenPHP image for the experimental Doppar worker-mode stack. Same PHP
# extension surface as the FPM image (pdo_sqlite, opcache) so the only variable
# versus Doppar-FPM is the runtime model (persistent worker vs process-per-request).
FROM dunglas/frankenphp:latest
RUN install-php-extensions pdo_sqlite opcache
