#!/usr/bin/env bash
#
# bench.sh — one entrypoint for the whole doppar-bench workflow.
#
# The host needs only Docker (with the Compose plugin) and git. PHP, Composer,
# wrk and even the results generator run in containers.
#
#   ./bench.sh all                 build apps + benchmark every stack + write
#                                  RESULTS.md + tear everything down
#   ./bench.sh setup               build images + (re)create the three apps
#   ./bench.sh run [stack...]      benchmark all stacks (or the ones named)
#   ./bench.sh doppar-fpm          benchmark a single stack (shorthand for run)
#   ./bench.sh doppar-worker
#   ./bench.sh laravel
#   ./bench.sh symfony
#   ./bench.sh ab [stack...]       OPTIONAL ApacheBench cross-check (ab -n 50000
#                                  -c 1000, no keep-alive) — NOT part of `all`
#   ./bench.sh results             (re)generate RESULTS.md from results/*/
#   ./bench.sh down                stop and remove all benchmark containers
#   ./bench.sh help
#
# Useful env overrides (see README): REPEATS, WARMUP, COOLDOWN, STAGES,
# HOST_TAG, RESULTS_DIR, BENCH_PORT_BASE.
#
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$PWD"

ALL_PROFILES=(--profile doppar --profile doppar-worker --profile laravel --profile symfony)

die() { echo "error: $*" >&2; exit 1; }

need_docker() {
  command -v docker >/dev/null 2>&1 || die "Docker is required but not found on PATH."
  docker compose version >/dev/null 2>&1 || die "The Docker Compose plugin (docker compose) is required."
}

apps_ready() {
  [ -d "$ROOT/apps/doppar/vendor" ] && [ -d "$ROOT/apps/laravel/vendor" ] && [ -d "$ROOT/apps/symfony/vendor" ]
}
ensure_setup() { apps_ready || bash "$ROOT/bench/setup.sh"; }

# Generate RESULTS.md. Prefer host python3; fall back to a python container so a
# host with only Docker still works (the container output is chowned back).
gen_results() {
  if command -v python3 >/dev/null 2>&1; then
    python3 "$ROOT/bench/gen_results.py"
  else
    echo ">> no host python3; generating RESULTS.md in a container"
    docker run --rm -v "$ROOT":/work -w /work python:3-alpine python bench/gen_results.py
    docker run --rm -v "$ROOT":/work alpine:3.20 chown "$(id -u):$(id -g)" /work/RESULTS.md 2>/dev/null || true
  fi
}

down() {
  docker compose "${ALL_PROFILES[@]}" down >/dev/null 2>&1 || true
  echo ">> all benchmark containers stopped."
}

usage() { sed -n '3,30p' "$0" | sed 's/^# \{0,1\}//'; }

cmd="${1:-help}"; shift || true

case "$cmd" in
  all)
    need_docker
    bash "$ROOT/bench/setup.sh"
    bash "$ROOT/bench/run.sh"
    gen_results
    down
    echo ">> done. See RESULTS.md"
    ;;
  setup)
    need_docker
    bash "$ROOT/bench/setup.sh"
    ;;
  run)
    need_docker; ensure_setup
    STACKS="${*:-${STACKS:-doppar-fpm doppar-worker laravel symfony}}" bash "$ROOT/bench/run.sh"
    gen_results
    ;;
  doppar-fpm|doppar-worker|laravel|symfony)
    need_docker; ensure_setup
    STACKS="$cmd" bash "$ROOT/bench/run.sh"
    gen_results
    ;;
  ab)
    # Optional ApacheBench cross-check — deliberately separate from `all`/`run`
    # (our published methodology is wrk). Same apps, same endpoints, different generator.
    need_docker; ensure_setup
    STACKS="${*:-${STACKS:-doppar-fpm doppar-worker laravel symfony}}" bash "$ROOT/bench/run-ab.sh"
    gen_results
    ;;
  results)
    gen_results
    ;;
  down)
    need_docker; down
    ;;
  help|-h|--help)
    usage
    ;;
  *)
    echo "unknown command: $cmd" >&2
    usage
    exit 1
    ;;
esac
