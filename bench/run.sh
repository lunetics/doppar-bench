#!/usr/bin/env bash
#
# run.sh — drive the doppar-bench load test.
#
# Portable: needs only Docker + Compose on the host. PHP, Composer, wrk and the
# readiness probe all run in containers — nothing else is assumed on the host.
#
# ROUND-BASED INTERLEAVING: each ROUND runs every stack once (only one stack plus
# wrk is ever up at a time), so a stack's repeats are spread across the whole run
# and time-varying host load affects all stacks equally rather than biasing
# whichever ran during a busy window. A cooldown between runs lets the CPU recover.
#
# Results are written PER HOST to results/<hostname>-<date>/ so runs from several
# machines can coexist. Override via env vars, e.g.:
#   STACKS="doppar-fpm laravel symfony" REPEATS=3 ./bench/run.sh
#   HOST_TAG=bigserver-20260723 BENCH_PORT_BASE=19000 ./bench/run.sh
#
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"

# ---- configuration ----------------------------------------------------------
STACKS="${STACKS:-doppar-fpm laravel symfony doppar-worker laravel-worker symfony-worker}"
ENDPOINTS="${ENDPOINTS:-json db}"
# Vendor load stages: "threads connections duration_seconds".
STAGES_DEFAULT=$'2 50 20\n4 200 30\n8 500 60'
STAGES="${STAGES:-$STAGES_DEFAULT}"
REPEATS="${REPEATS:-3}"          # number of rounds; median across rounds is reported
WARMUP="${WARMUP:-6}"            # discarded warmup seconds per endpoint per round
READY_TIMEOUT="${READY_TIMEOUT:-60}"
COOLDOWN="${COOLDOWN:-6}"        # seconds between wrk runs (thermal recovery + settle)

# Per-host results directory (raw reports + captured environment live here).
HOST_TAG="${HOST_TAG:-$(hostname)-$(date +%Y%m%d)}"
RESULTS_DIR="${RESULTS_DIR:-$ROOT/results/$HOST_TAG}"
RAW="$RESULTS_DIR/raw"
mkdir -p "$RAW"

# Host port exposure is optional (readiness is checked in-network); derive it
# from BENCH_PORT_BASE so nothing collides on a shared host. Exported for compose.
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

# Doppar writes a new session file per (cookieless) request. Clear the tmpfs
# sessions dir before each run so accumulation from a previous run can't slow a
# later stage via directory scaling. No-op for the stateless Laravel/Symfony.
clean_sessions() {
  local svc
  case "$1" in
    doppar-fpm)    svc=php-doppar;;
    doppar-worker) svc=frankenphp-doppar;;
    *) return 0;;
  esac
  # </dev/null is REQUIRED: like `compose run`, `compose exec` reads stdin and
  # would otherwise swallow the stage here-string loop that calls this.
  dc exec -T "$svc" sh -c 'find /var/www/html/storage/framework/sessions -type f -delete 2>/dev/null' </dev/null >/dev/null 2>&1 || true
}

# Readiness is checked from INSIDE the compose network with busybox wget (shipped
# in the wrk image), so the host needs no curl/wget and no published port.
wait_ready() {
  local host="$1" i
  for ((i=0; i<READY_TIMEOUT; i++)); do
    dc run --rm -T --entrypoint wget wrk -q -T 2 -O /dev/null "http://${host}/json" </dev/null >/dev/null 2>&1 && return 0
    sleep 1
  done
  echo "!! stack $host did not become ready within ${READY_TIMEOUT}s" >&2
  return 1
}

# ---- provenance (portable; falls back to /proc when lscpu/nproc are absent) --
capture_env() {
  local cpu cores mem
  cpu="$(LC_ALL=C lscpu 2>/dev/null | sed -n 's/^Model name:[[:space:]]*//p' | head -1)"
  [ -z "$cpu" ] && cpu="$(sed -n 's/^model name[[:space:]]*:[[:space:]]*//p' /proc/cpuinfo 2>/dev/null | head -1)"
  cores="$(nproc 2>/dev/null || grep -c '^processor' /proc/cpuinfo 2>/dev/null)"
  mem="$(awk '/MemTotal/{printf "%.0f GiB", $2/1024/1024}' /proc/meminfo 2>/dev/null)"
  {
    echo "# doppar-bench environment"
    echo "host_tag: $HOST_TAG"
    echo "hostname: $(hostname)"
    echo "date_utc: $(date -u +%FT%TZ)"
    echo "kernel: $(uname -sr)"
    echo "cpu: ${cpu:-unknown}"
    echo "cpu_logical: ${cores:-unknown}"
    echo "mem_total: ${mem:-unknown}"
    echo "storage: $(lsblk -dn -o NAME,ROTA,MODEL 2>/dev/null | grep -Ev '^(loop|sr|zram|ram)' | while read -r n r m; do printf '%s=%s%s; ' "$n" "$([ "$r" = 1 ] && echo HDD || echo SSD)" "${m:+ ($m)}"; done)"
    # `|| true`: systemd-detect-virt exits 1 on bare metal ("none"), which would
    # abort the script under `set -e`.
    local virt; virt="$(systemd-detect-virt 2>/dev/null || true)"
    echo "virtualization: ${virt:-unknown}"
    echo "docker: $(docker --version 2>/dev/null)"
    echo "compose: $(docker compose version --short 2>/dev/null)"
    echo "stages: $(echo "$STAGES" | tr '\n' ';')"
    echo "rounds(repeats): $REPEATS  warmup: ${WARMUP}s  cooldown: ${COOLDOWN}s  scheduling: interleaved"
    echo "stacks: $STACKS"
  } >"$RESULTS_DIR/env.txt"
}

echo ">> results dir: $RESULTS_DIR"
capture_env

echo ">> building images"
dc build wrk >/dev/null

echo ">> clean slate (down any running stacks)"
dc --profile doppar --profile doppar-worker --profile laravel --profile symfony down >/dev/null 2>&1 || true

# ---- main loop (rounds outermost, stacks interleaved) -----------------------
for ((round=1; round<=REPEATS; round++)); do
  echo ""
  echo "###################  ROUND $round / $REPEATS  ###################"
  for stack in $STACKS; do
    prof="$(profile_of "$stack")"; host="$(host_of "$stack")"
    echo ">> [$round] stack $stack (profile=$prof host=$host)"

    dc --profile "$prof" up -d --build >/dev/null
    wait_ready "$host"

    for ep in $ENDPOINTS; do
      path="/$ep"
      # warmup (discarded) — the container came up cold, so prime OPcache/JIT/DB.
      # NOTE: </dev/null is REQUIRED — `compose run` otherwise consumes the
      # here-string feeding the `while read stage` loop below.
      clean_sessions "$stack"
      dc run --rm -T wrk -t4 -c100 -d"${WARMUP}s" "http://${host}${path}" </dev/null >/dev/null 2>&1 || true
      while IFS= read -r stage; do
        [ -z "$stage" ] && continue
        read -r t c d <<<"$stage"
        out="$RAW/${stack}__${ep}__t${t}c${c}d${d}__run${round}.txt"
        printf "   %s %s  t%s/c%s/d%ss  round %d ... " "$stack" "$path" "$t" "$c" "$d" "$round"
        clean_sessions "$stack"
        dc run --rm -T wrk -t"$t" -c"$c" -d"${d}s" --latency "http://${host}${path}" </dev/null >"$out" 2>&1
        echo "$(sed -n 's/^Requests\/sec:[[:space:]]*//p' "$out" | head -1) req/s"
        sleep "$COOLDOWN"
      done <<<"$STAGES"
    done

    dc --profile "$prof" down >/dev/null
  done
done

echo ""
echo ">> done. Raw reports: $RAW ($(ls -1 "$RAW"/*.txt 2>/dev/null | wc -l) files)"
echo ">> generate the table with: python3 bench/gen_results.py"
