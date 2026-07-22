# Runbook: run this benchmark on your own machine

Step-by-step guide for running doppar-bench on a fresh Linux host, written for
someone seeing this repository for the first time.

## Prerequisites

- Docker Engine with the Compose v2 plugin (`docker compose version` works).
- Python 3 (any recent version, standard library only) for the results
  generator.
- Free TCP ports 18010, 18020, 18030, 18040.
- Roughly 2 GB of free disk for images, vendor directories and results.

Nothing else touches the host: PHP, Composer and wrk all run inside
containers.

## Get the code

```bash
git clone https://github.com/lunetics/doppar-bench.git
cd doppar-bench
```

(Copying the directory with rsync/scp from another machine works just as
well — `vendor/` is gitignored and rebuilt by setup.)

## Run

```bash
./bench/setup.sh               # build images, composer install, migrate + seed, warm caches
./bench/run.sh                 # full benchmark, ~50 min with defaults
python3 bench/gen_results.py   # regenerate RESULTS.md from results/raw/
```

`run.sh` prints progress per wrk run. Raw wrk reports land in `results/raw/`,
a snapshot of the host environment in `results/env.txt`. Only one stack (plus
wrk) is ever up at a time; rounds are interleaved across stacks so
time-varying host load biases no single framework.

## Tuning

All knobs are environment variables (see the header of `bench/run.sh`):

```bash
# Skip the experimental FrankenPHP worker stack, run two rounds only:
STACKS="doppar-fpm laravel symfony" REPEATS=2 ./bench/run.sh

# Longer cooldown between wrk runs (thermal headroom on small machines):
COOLDOWN=10 ./bench/run.sh
```

Keep the php-fpm pool settings (`docker/php/`, `pm.max_children=16`) unchanged
if you want your numbers comparable with other hosts' runs of this repo — the
value is part of the methodology, not a per-host tweak.

## Keeping results from multiple hosts

`results/raw/` and `RESULTS.md` describe one run on one host, and a new run
overwrites the previous raw reports. To keep several machines side by side,
archive after generating:

```bash
python3 bench/gen_results.py
cp RESULTS.md "RESULTS-$(hostname).md"
cp -r results/raw "results/raw-$(hostname)"
```

or commit each host's run on its own branch
(`git checkout -b results/$(hostname)`).

## Aborting and cleanup

Ctrl-C the runner, then from the repo root:

```bash
docker compose down --remove-orphans
```

Re-running is safe: `setup.sh` is idempotent, and `run.sh` starts and tears
down each stack itself.
