#!/usr/bin/env bash
#
# setup.sh — reproduce the three benchmark applications from a clean checkout.
#
# Everything runs in containers; the host needs only Docker. For each app this
# installs dependencies from the committed composer.lock, applies the committed
# .env.bench, creates + seeds the SQLite database with one deterministic row,
# and warms the production caches. Idempotent: safe to re-run.
#
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"

PHP_IMAGE="doppar-bench/php:8.5"

# run_in <app-dir> <command...>  — run a command in the php image with the app
# mounted at the RUNTIME path (/var/www/html) so cached absolute paths match.
run_in() {
  local dir="$1"; shift
  docker run --rm -e COMPOSER_NO_INTERACTION=1 -v "$dir":/var/www/html -w /var/www/html "$PHP_IMAGE" "$@"
}
own() { docker run --rm -v "$1":/t alpine:3.20 chown -R "$(id -u):$(id -g)" /t; }
perm() { docker run --rm -v "$1":/t alpine:3.20 sh -c "$2"; }

echo ">> building images (shared php, wrk, frankenphp)"
docker compose build php-doppar frankenphp-doppar >/dev/null
docker build -t doppar-bench/wrk:4.2.0 docker/wrk >/dev/null

# ---------------------------------------------------------------- Doppar
D="$ROOT/apps/doppar"
echo ">> doppar (3.x): install + migrate + seed + cache"
run_in "$D" composer install --no-interaction --no-scripts >/dev/null
own "$D"
cp "$D/.env.bench" "$D/.env"
mkdir -p "$D/database"; : > "$D/database/database.sqlite"
run_in "$D" php pool key:generate >/dev/null
run_in "$D" php pool migrate >/dev/null
run_in "$D" php pool db:seed >/dev/null
run_in "$D" php pool config:cache >/dev/null
run_in "$D" php pool route:cache >/dev/null
perm "$D" 'chmod -R 0777 /t/storage /t/database; chmod 0666 /t/database/database.sqlite'

# ---------------------------------------------------------------- Laravel
L="$ROOT/apps/laravel"
echo ">> laravel (13.x): install + migrate + seed + cache"
run_in "$L" composer install --no-interaction --no-scripts >/dev/null
own "$L"
cp "$L/.env.bench" "$L/.env"
mkdir -p "$L/database"; : > "$L/database/database.sqlite"
run_in "$L" php artisan key:generate >/dev/null
run_in "$L" php artisan migrate --force >/dev/null
run_in "$L" php artisan db:seed --force >/dev/null
run_in "$L" php artisan config:cache >/dev/null
run_in "$L" php artisan route:cache >/dev/null
perm "$L" 'chmod -R 0777 /t/storage /t/bootstrap/cache /t/database; chmod 0666 /t/database/database.sqlite'

# ---------------------------------------------------------------- Symfony
S="$ROOT/apps/symfony"
echo ">> symfony (8.x): install + schema + seed + cache"
run_in "$S" composer install --no-interaction --no-scripts >/dev/null
own "$S"
cp "$S/.env.bench" "$S/.env"
mkdir -p "$S/var"; : > "$S/var/bench.db"
run_in "$S" php bin/console doctrine:schema:create >/dev/null
run_in "$S" php bin/console dbal:run-sql \
  "INSERT INTO users (name,email) VALUES ('Benchmark User','bench@doppar-bench.test')" >/dev/null
run_in "$S" composer dump-env prod >/dev/null
run_in "$S" php bin/console cache:clear >/dev/null
run_in "$S" php bin/console cache:warmup >/dev/null
perm "$S" 'chmod -R 0777 /t/var; chmod 0666 /t/var/bench.db'

echo ">> setup complete. Run the benchmark with: ./bench/run.sh"
