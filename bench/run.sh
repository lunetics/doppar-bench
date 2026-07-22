#!/usr/bin/env bash
#
# run.sh — drive the doppar-bench load test.
#
# For each stack (framework + runtime) it brings up ONLY that stack, warms it up,
# then runs wrk at the three vendor load stages, repeating each stage and writing
# every raw wrk report to results/raw/. Nothing but the stack under test and wrk
# is ever running, so the measurement is sequential and uncontended.
#
# Override behaviour via env vars, e.g.:
#   STACKS="doppar-fpm laravel symfony" REPEATS=2 ./bench/run.sh
#
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
RAW="$ROOT/results/raw"
mkdir -p "$RAW"

# ---- configuration ----------------------------------------------------------
# Stacks to benchmark (space separated). doppar-worker is experimental — see README.
STACKS="${STACKS:-doppar-fpm doppar-worker laravel symfony}"
ENDPOINTS="${ENDPOINTS:-json db}"
# Vendor load stages: "threads connections duration_seconds".
STAGES_DEFAULT=$'2 50 20\n4 200 30\n8 500 60'
STAGES="${STAGES:-$STAGES_DEFAULT}"
REPEATS="${REPEATS:-3}"          # repeats per stage (median is reported)
WARMUP="${WARMUP:-10}"           # discarded warmup seconds per endpoint
READY_TIMEOUT="${READY_TIMEOUT:-45}"
COOLDOWN="${COOLDOWN:-2}"        # seconds between runs to let the server settle

# Per-stack metadata: compose profile, in-network host (wrk target), host port (readiness).
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
    if curl -fsS -o /dev/null "$url" 2>/dev/null; then return 0; fi
    sleep 1
  done
  echo "!! stack did not become ready on port $port within ${READY_TIMEOUT}s" >&2
  return 1
}

run_wrk() { # threads conn dur host path outfile
  local t="$1" c="$2" d="$3" host="$4" path="$5" out="$6"
  dc run --rm -T wrk -t"$t" -c"$c" -d"${d}s" --latency "http://${host}${path}" >"$out" 2>&1
}

# ---- provenance -------------------------------------------------------------
{
  echo "# doppar-bench environment"
  echo "date_utc: $(date -u +%FT%TZ)"
  echo "kernel: $(uname -sr)"
  echo "cpu: $(lscpu | sed -n 's/^Model name:[[:space:]]*//p' | head -1)"
  echo "cpu_logical: $(nproc)"
  echo "mem_total: $(awk '/MemTotal/{printf "%.0f GiB", $2/1024/1024}' /proc/meminfo)"
  echo "docker: $(docker --version)"
  echo "compose: $(docker compose version --short 2>/dev/null)"
  echo "stages: $(echo "$STAGES" | tr '\n' ';')"
  echo "repeats: $REPEATS  warmup: ${WARMUP}s"
  echo "stacks: $STACKS"
} >"$ROOT/results/env.txt"

echo ">> building images"
dc build wrk >/dev/null

echo ">> clean slate (down any running stacks)"
dc --profile doppar --profile doppar-worker --profile laravel --profile symfony down >/dev/null 2>&1 || true

# ---- main loop --------------------------------------------------------------
for stack in $STACKS; do
  prof="$(profile_of "$stack")"; host="$(host_of "$stack")"; port="$(port_of "$stack")"
  echo ""
  echo "==================================================================="
  echo ">> STACK: $stack   (profile=$prof host=$host port=$port)"
  echo "==================================================================="

  dc --profile "$prof" up -d --build >/dev/null
  wait_ready "$port"
  echo "   ready."

  for ep in $ENDPOINTS; do
    path="/$ep"
    echo "   -- endpoint $path : warmup ${WARMUP}s (discarded)"
    dc run --rm -T wrk -t4 -c100 -d"${WARMUP}s" "http://${host}${path}" >/dev/null 2>&1 || true

    while IFS= read -r stage; do
      [ -z "$stage" ] && continue
      read -r t c d <<<"$stage"
      for ((r=1; r<=REPEATS; r++)); do
        out="$RAW/${stack}__${ep}__t${t}c${c}d${d}__run${r}.txt"
        printf "   -- %s %s  t%s/c%s/d%ss  run %d/%d ... " "$stack" "$path" "$t" "$c" "$d" "$r" "$REPEATS"
        run_wrk "$t" "$c" "$d" "$host" "$path" "$out"
        rps=$(sed -n 's/^Requests\/sec:[[:space:]]*//p' "$out")
        echo "${rps:-ERR} req/s"
        sleep "$COOLDOWN"
      done
    done <<<"$STAGES"
  done

  dc --profile "$prof" down >/dev/null
  echo "   stack down."
done

echo ""
echo ">> all stacks done. Raw reports in results/raw/ ($(ls -1 "$RAW"/*.txt 2>/dev/null | wc -l) files)"
echo ">> generate the table with: python3 bench/gen_results.py"
