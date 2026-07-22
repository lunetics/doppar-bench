# Runbook — run this benchmark on your own machine

Step‑by‑step guide for running `doppar-bench` on a Linux host you have never used
it on before. It benchmarks Doppar, Laravel and Symfony against each other and
writes the numbers for **your** machine alongside any existing ones.

## 1. Prerequisites

You need only three things on the host:

- **Linux** (bare metal, VM, or something like TrueNAS SCALE — anything with a
  normal Linux userland).
- **Docker** with the **Compose v2 plugin** (`docker compose version` must work).
- **git** (only to obtain the repo; a plain copy works too).

Everything else — PHP 8.5, Composer, wrk, and even the results generator — runs
inside containers. You do **not** need PHP, Composer, wrk, Node, or `gh` on the
host. `python3` is used for the results table if present; if it isn't, a Python
container is used automatically.

Rough resource needs: a few GB of disk for the images, and enough RAM/CPU to be
worth benchmarking. The images are built on first run.

## 2. Get the repo

```bash
git clone https://github.com/lunetics/doppar-bench.git
cd doppar-bench
# …or copy the directory onto the host (vendor/ is gitignored and rebuilt) and cd in.
```

## 3. Run everything — one command

```bash
./bench.sh all
```

This will, in order: build the shared images (PHP‑FPM, nginx, wrk, FrankenPHP);
create and seed the three applications; benchmark every stack sequentially (only
one stack plus the load generator is ever running at once); write `RESULTS.md`;
and tear all benchmark containers down.

**How long:** roughly **45–60 minutes** for the full default run (4 stacks × 2
endpoints × 3 load stages × 3 interleaved rounds, with warmups and cooldowns).
The first run also spends a few minutes building images.

## 4. Where the results land

- **`results/<hostname>-<date>/raw/`** — every raw `wrk` report (kept as evidence).
- **`results/<hostname>-<date>/env.txt`** — the captured environment (CPU, RAM,
  kernel, Docker/Compose versions) for that run.
- **`RESULTS.md`** — the generated tables. It aggregates **all** host directories,
  so several machines' runs appear as separate sections and can be compared.

Because results are keyed by hostname + date, running on a new machine never
overwrites another machine's numbers — no manual archiving needed.

## 5. Partial runs and re‑runs

```bash
./bench.sh setup            # just build images + (re)create the apps
./bench.sh run              # benchmark all stacks (apps must be set up)
./bench.sh laravel          # benchmark a single stack: doppar-fpm|doppar-worker|laravel|symfony
./bench.sh results          # just (re)generate RESULTS.md from results/*/
./bench.sh down             # stop/remove all benchmark containers
```

`setup` is idempotent, and `run` starts and tears down each stack itself.

## 6. Tuning (optional environment variables)

```bash
REPEATS=5 ./bench.sh run                       # more rounds -> tighter median
STAGES=$'2 50 10\n4 200 10' ./bench.sh run     # custom wrk stages "threads conn seconds"
STACKS="laravel symfony" ./bench.sh run        # subset of stacks
COOLDOWN=10 ./bench.sh run                      # more thermal headroom between runs
BENCH_PORT_BASE=19000 ./bench.sh all           # move host debug ports if the 18000s are taken
HOST_TAG=bigserver-20260723 ./bench.sh all     # override the results directory name
```

Keep the php‑fpm pool (`docker/php/`, `pm.max_children=16`) unchanged if you want
your numbers comparable with other hosts' runs — it is part of the methodology,
not a per‑host tweak.

Host ports are only for manual debugging (e.g. `curl localhost:18010/json`); the
benchmark talks to the stacks over the internal Docker network, so a port clash
never affects measurement — but `BENCH_PORT_BASE` lets you move them anyway.

## 7. Aborting a run cleanly

Press `Ctrl‑C` to stop `bench.sh`. `run.sh` tears each stack down after it is
done, but an interrupted run may leave the current stack up. Clear it with:

```bash
./bench.sh down
```

## 8. Contributing your machine's numbers

`results/<host>/` is **not** git‑ignored (only `vendor/` and generated app state
are). To add your machine to the comparison, commit your `results/<host>/`
directory and re‑run `./bench.sh results` so `RESULTS.md` includes it.

## 9. Troubleshooting

- **`docker compose` not found** → install the Compose v2 plugin. The legacy
  `docker-compose` binary is not used.
- **Port already in use** → set `BENCH_PORT_BASE` to a free range.
- **A stack won't become ready** → check `docker compose --profile <name> logs`;
  readiness (checked in‑network, no host tools needed) waits up to 60s
  (`READY_TIMEOUT`).
- **No `python3` on the host** → nothing to do; `bench.sh` runs the generator in a
  container automatically.
- **Permission errors deleting the checkout after an aborted setup** → a failed
  `setup.sh` can leave container-owned `vendor/` files behind (the chown step
  only runs after a successful install). Clear them with
  `docker run --rm -v "$PWD":/t alpine:3.20 sh -c 'rm -rf /t/apps/doppar/vendor /t/apps/laravel/vendor /t/apps/symfony/vendor'`
  and re-run `./bench.sh setup`.
