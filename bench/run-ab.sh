#!/usr/bin/env bash
#
# run-ab.sh — OPTIONAL ApacheBench cross-check.
#
# Mirrors the OLDER vendor methodology (dev.to, Sept 2025): ApacheBench, 50,000
# requests at 1,000 concurrency against a DB-backed endpoint, with no documented
# flags. This is deliberately NOT our published methodology (that is wrk, in
# run.sh) — it exists only to reproduce the second set of vendor numbers on the
# exact same application containers.
#
# Same stacks, same endpoints, same app setup as the wrk run; only the load
# generator differs. Results go to results/<host>/raw-ab/ so they never mix with
# the wrk reports in results/<host>/raw/.
#
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"

STACKS="${STACKS:-doppar-fpm laravel symfony doppar-worker laravel-worker symfony-worker}"
ENDPOINTS="${ENDPOINTS:-json db}"
# Exactly the documented vendor load.
AB_N="${AB_N:-50000}"
AB_C="${AB_C:-1000}"
REPEATS="${REPEATS:-2}"          # 2 repeats is plenty at 50k requests/run
WARMUP_N="${WARMUP_N:-3000}"     # discarded warmup requests (prime OPcache/JIT)
WARMUP_C="${WARMUP_C:-50}"
READY_TIMEOUT="${READY_TIMEOUT:-60}"
COOLDOWN="${COOLDOWN:-6}"

HOST_TAG="${HOST_TAG:-$(hostname)-$(date +%Y%m%d)}"
RESULTS_DIR="${RESULTS_DIR:-$ROOT/results/$HOST_TAG}"
RAW_AB="$RESULTS_DIR/raw-ab"
mkdir -p "$RAW_AB"

BENCH_PORT_BASE="${BENCH_PORT_BASE:-18000}"
export BENCH_PORT_DOPPAR="${BENCH_PORT_DOPPAR:-$((BENCH_PORT_BASE + 10))}"
export BENCH_PORT_WORKER="${BENCH_PORT_WORKER:-$((BENCH_PORT_BASE + 20))}"
export BENCH_PORT_LARAVEL="${BENCH_PORT_LARAVEL:-$((BENCH_PORT_BASE + 30))}"
export BENCH_PORT_SYMFONY="${BENCH_PORT_SYMFONY:-$((BENCH_PORT_BASE + 40))}"
export BENCH_PORT_LARAVEL_WORKER="${BENCH_PORT_LARAVEL_WORKER:-$((BENCH_PORT_BASE + 50))}"
export BENCH_PORT_SYMFONY_WORKER="${BENCH_PORT_SYMFONY_WORKER:-$((BENCH_PORT_BASE + 60))}"

profile_of() { case "$1" in
  doppar-fpm) echo doppar;; doppar-worker) echo doppar-worker;;
  laravel) echo laravel;; symfony) echo symfony;;
  laravel-worker) echo laravel-worker;; symfony-worker) echo symfony-worker;;
  *) echo "unknown stack: $1" >&2; exit 1;; esac; }
host_of() { case "$1" in
  doppar-fpm) echo nginx-doppar;; doppar-worker) echo frankenphp-doppar;;
  laravel) echo nginx-laravel;; symfony) echo nginx-symfony;;
  laravel-worker) echo laravel-worker;; symfony-worker) echo symfony-worker;;
  esac; }

dc() { docker compose "$@"; }

clean_sessions() {
  local svc
  case "$1" in
    doppar-fpm)    svc=php-doppar;;
    doppar-worker) svc=frankenphp-doppar;;
    *) return 0;;
  esac
  dc exec -T "$svc" sh -c 'find /var/www/html/storage/framework/sessions -type f -delete 2>/dev/null' </dev/null >/dev/null 2>&1 || true
}

wait_ready() {
  local host="$1" i
  for ((i=0; i<READY_TIMEOUT; i++)); do
    dc run --rm -T --entrypoint wget wrk -q -T 2 -O /dev/null "http://${host}/json" </dev/null >/dev/null 2>&1 && return 0
    sleep 1
  done
  echo "!! stack $host did not become ready within ${READY_TIMEOUT}s" >&2
  return 1
}

echo ">> ApacheBench cross-check -> $RAW_AB"
echo ">> load: ab -n $AB_N -c $AB_C  (NO -k: the vendor documented no keep-alive; ab's default is HTTP/1.0 without keep-alive, so we keep it off deliberately)"
dc build wrk ab >/dev/null
[ -f "$RESULTS_DIR/env.txt" ] || {
  { echo "# doppar-bench environment"; echo "host_tag: $HOST_TAG"; echo "hostname: $(hostname)"
    echo "date_utc: $(date -u +%FT%TZ)"; echo "kernel: $(uname -sr)"; echo "note: ab-only run"; } >"$RESULTS_DIR/env.txt"
}

dc --profile doppar --profile doppar-worker --profile laravel --profile symfony down >/dev/null 2>&1 || true

for ((round=1; round<=REPEATS; round++)); do
  echo ""
  echo "###################  AB ROUND $round / $REPEATS  ###################"
  for stack in $STACKS; do
    prof="$(profile_of "$stack")"; host="$(host_of "$stack")"
    echo ">> [$round] stack $stack (host=$host)"
    dc --profile "$prof" up -d --build >/dev/null
    wait_ready "$host"

    for ep in $ENDPOINTS; do
      path="/$ep"
      # warmup (discarded) — the container came up cold.
      # -n/-c are NOT read from stdin, so no </dev/null-vs-loop hazard here, but
      # we keep stdin closed for consistency with the rest of the harness.
      clean_sessions "$stack"
      dc run --rm -T ab -n "$WARMUP_N" -c "$WARMUP_C" "http://${host}${path}" </dev/null >/dev/null 2>&1 || true
      out="$RAW_AB/${stack}__${ep}__n${AB_N}c${AB_C}__run${round}.txt"
      printf "   %s %s  ab -n %s -c %s  round %d ... " "$stack" "$path" "$AB_N" "$AB_C" "$round"
      clean_sessions "$stack"
      dc run --rm -T ab -n "$AB_N" -c "$AB_C" "http://${host}${path}" </dev/null >"$out" 2>&1 || true
      echo "$(sed -n 's/^Requests per second:[[:space:]]*\([0-9.]*\).*/\1/p' "$out" | head -1) req/s, failed=$(sed -n 's/^Failed requests:[[:space:]]*//p' "$out" | head -1)"
      sleep "$COOLDOWN"
    done

    dc --profile "$prof" down >/dev/null
  done
done

echo ""
echo ">> ab done. Raw reports: $RAW_AB ($(ls -1 "$RAW_AB"/*.txt 2>/dev/null | wc -l) files)"
echo ">> regenerate the tables with: python3 bench/gen_results.py"
