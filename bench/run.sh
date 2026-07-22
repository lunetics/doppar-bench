#!/usr/bin/env bash
#
# run.sh — drive the doppar-bench load test.
#
# ROUND-BASED INTERLEAVING: instead of running every repeat of one stack before
# moving to the next, each ROUND runs every stack once. Only one stack (plus wrk)
# is ever up at a time — but a stack's three repeats are spread across the whole
# run, so any time-varying load on the (shared, desktop) host affects all stacks
# roughly equally rather than biasing whichever stack happened to run during a
# busy window. A cooldown between every wrk run lets the CPU recover, which
# removes the thermal-throttling decline seen with back-to-back runs.
#
# Override via env vars, e.g.:
#   STACKS="doppar-fpm laravel symfony" REPEATS=3 COOLDOWN=8 ./bench/run.sh
#
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
RAW="$ROOT/results/raw"
mkdir -p "$RAW"

# ---- configuration ----------------------------------------------------------
STACKS="${STACKS:-doppar-fpm doppar-worker laravel symfony}"
ENDPOINTS="${ENDPOINTS:-json db}"
# Vendor load stages: "threads connections duration_seconds".
STAGES_DEFAULT=$'2 50 20\n4 200 30\n8 500 60'
STAGES="${STAGES:-$STAGES_DEFAULT}"
REPEATS="${REPEATS:-3}"          # number of rounds; median across rounds is reported
WARMUP="${WARMUP:-6}"            # discarded warmup seconds per endpoint per round
READY_TIMEOUT="${READY_TIMEOUT:-45}"
COOLDOWN="${COOLDOWN:-6}"        # seconds between wrk runs (thermal recovery + settle)

profile_of() { case "$1" in
  doppar-fpm) echo doppar;; doppar-worker) echo doppar-worker;;
  laravel) echo laravel;; symfony) echo symfony;;
  *) echo "unknown stack: $1" >&2; exit 1;; esac; }
host_of() { case "$1" in
  doppar-fpm) echo nginx-doppar;; doppar-worker) echo frankenphp-doppar;;
  laravel) echo nginx-laravel;; symfony) echo nginx-symfony;;
  esac; }
port_of() { case "$1" in
  doppar-fpm) echo 18010;; doppar-worker) echo 18020;;
  laravel) echo 18030;; symfony) echo 18040;; esac; }

dc() { docker compose "$@"; }

wait_ready() {
  local port="$1" url="http://localhost:$port/json" i
  for ((i=0; i<READY_TIMEOUT; i++)); do
    curl -fsS -o /dev/null "$url" 2>/dev/null && return 0
    sleep 1
  done
  echo "!! stack did not become ready on port $port within ${READY_TIMEOUT}s" >&2
  return 1
}

# ---- provenance -------------------------------------------------------------
{
  echo "# doppar-bench environment"
  echo "date_utc: $(date -u +%FT%TZ)"
  echo "kernel: $(uname -sr)"
  echo "cpu: $(LC_ALL=C lscpu | sed -n 's/^Model name:[[:space:]]*//p' | head -1)"
  echo "cpu_logical: $(nproc)"
  echo "mem_total: $(awk '/MemTotal/{printf "%.0f GiB", $2/1024/1024}' /proc/meminfo)"
  echo "docker: $(docker --version)"
  echo "compose: $(docker compose version --short 2>/dev/null)"
  echo "stages: $(echo "$STAGES" | tr '\n' ';')"
  echo "rounds(repeats): $REPEATS  warmup: ${WARMUP}s  cooldown: ${COOLDOWN}s  scheduling: interleaved"
  echo "stacks: $STACKS"
} >"$ROOT/results/env.txt"

echo ">> building images"
dc build wrk >/dev/null

echo ">> clean slate (down any running stacks)"
dc --profile doppar --profile doppar-worker --profile laravel --profile symfony down >/dev/null 2>&1 || true

# ---- main loop (rounds outermost, stacks interleaved) -----------------------
for ((round=1; round<=REPEATS; round++)); do
  echo ""
  echo "###################  ROUND $round / $REPEATS  ###################"
  for stack in $STACKS; do
    prof="$(profile_of "$stack")"; host="$(host_of "$stack")"; port="$(port_of "$stack")"
    echo ">> [$round] stack $stack (profile=$prof host=$host)"

    dc --profile "$prof" up -d --build >/dev/null
    wait_ready "$port"

    for ep in $ENDPOINTS; do
      path="/$ep"
      # warmup (discarded) — the container came up cold, so prime OPcache/JIT/DB.
      # NOTE: </dev/null is REQUIRED — `docker compose run` otherwise consumes the
      # here-string feeding the `while read stage` loop below, so only the first
      # stage would ever run.
      dc run --rm -T wrk -t4 -c100 -d"${WARMUP}s" "http://${host}${path}" </dev/null >/dev/null 2>&1 || true
      while IFS= read -r stage; do
        [ -z "$stage" ] && continue
        read -r t c d <<<"$stage"
        out="$RAW/${stack}__${ep}__t${t}c${c}d${d}__run${round}.txt"
        printf "   %s %s  t%s/c%s/d%ss  round %d ... " "$stack" "$path" "$t" "$c" "$d" "$round"
        dc run --rm -T wrk -t"$t" -c"$c" -d"${d}s" --latency "http://${host}${path}" </dev/null >"$out" 2>&1
        echo "$(sed -n 's/^Requests\/sec:[[:space:]]*//p' "$out" | head -1) req/s"
        sleep "$COOLDOWN"
      done <<<"$STAGES"
    done

    dc --profile "$prof" down >/dev/null
  done
done

echo ""
echo ">> done. Raw reports in results/raw/ ($(ls -1 "$RAW"/*.txt 2>/dev/null | wc -l) files)"
echo ">> generate the table with: python3 bench/gen_results.py"
