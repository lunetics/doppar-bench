# doppar-bench

**The first independent throughput benchmark of the [Doppar](https://doppar.com)
PHP framework against Laravel and Symfony.**

Every performance number published about Doppar so far traces back to its author.
The framework's own docs show a "Benchmark Snapshot" of ~2,000–2,100 req/s
([doppar.com/versions/3.x/getting-started](https://doppar.com/versions/3.x/getting-started),
retrieved 2026‑07‑22), and the widely‑quoted "7–8× faster than Laravel" figure
comes from the author's personal Medium/dev.to posts — the Laravel side of that
comparison was never actually run, only asserted. No third party has published a
reproducible, same‑hardware comparison: the independent PHP framework benchmark
at [trongate.io/benchmarks](https://trongate.io/benchmarks) does not include
Doppar, and there was no Hacker News or Reddit discussion of it as of 2026‑07‑22.

This repository is that missing independent measurement. It runs Doppar, Laravel
and Symfony on **identical** infrastructure — same PHP 8.5, same nginx, same
OPcache, same php‑fpm pool, same SQLite schema — and loads them with the exact
`wrk` stages the vendor used, so any difference reflects the frameworks, not the
setup.

A results write‑up will follow on the blog:
**https://fsck.sh/en/blog/doppar-php-framework-speed-demon/**

## What is measured

Two endpoints per framework, mirroring the vendor's methodology:

| Endpoint | What it does | Measures |
|---|---|---|
| `/json` | returns a small static JSON payload | framework routing + response overhead floor (no DB) |
| `/db`   | fetches one row by primary key through the framework's own ORM, as JSON | the vendor's `User::find(1)` round‑trip |

Each endpoint is hit at the three vendor load stages, after a discarded warmup,
across three **interleaved rounds**; the **median** requests/sec is reported. The
run is round‑based — every round runs all stacks once, so a stack's three samples
are spread over the whole run and any time‑varying load on the (shared desktop)
host affects all stacks roughly equally instead of biasing whichever stack ran
during a busy window. A cooldown between every run lets the CPU recover, removing
the thermal‑throttling decline that appears with back‑to‑back runs.

| Stage | wrk threads | connections | duration |
|---|---|---|---|
| baseline | 2 | 50 | 20 s |
| ramp | 4 | 200 | 30 s |
| saturation | 8 | 500 | 60 s |

Results land in [`RESULTS.md`](./RESULTS.md); raw `wrk` reports are kept under
[`results/raw/`](./results/raw/) as part of the deliverable.

## Stacks

| Stack | Server | Runtime model |
|---|---|---|
| **Doppar (PHP‑FPM)** | nginx + php‑fpm | process‑per‑request |
| **Laravel (PHP‑FPM)** | nginx + php‑fpm | process‑per‑request |
| **Symfony (PHP‑FPM)** | nginx + php‑fpm | process‑per‑request |
| **Doppar (FrankenPHP worker)** ¹ | FrankenPHP / Caddy | persistent in‑memory worker |

¹ **Experimental, not a controlled comparison.** The original post credits
Doppar's speed to a "worker mode" started with `php pool server:start` — but that
command only launches PHP's built‑in single‑process dev server; Doppar ships **no
persistent worker runtime**. To measure worker mode at all we wrote a custom
FrankenPHP worker that boots the Doppar app once and reuses it across requests
(see [`apps/doppar/public/frankenphp-worker.php`](./apps/doppar/public/frankenphp-worker.php)).
It works, but it swaps nginx+php‑fpm for FrankenPHP/Caddy — so it changes the web
server **and** the runtime model at once. Read that row as "can Doppar run as a
persistent worker, and roughly how fast", not as a like‑for‑like comparison.

## Versions

| Component | Version |
|---|---|
| Doppar (`doppar/framework`) | 3.26.5 |
| Laravel (`laravel/framework`) | 13.21.1 |
| Symfony (`symfony/framework-bundle`) | 8.1.1 |
| PHP | 8.5.8 (NTS, cli/fpm) |
| nginx | 1.27‑alpine |
| FrankenPHP | `dunglas/frankenphp:latest` (worker stack only) |
| wrk | 4.2.0 (built from source) |

Exact dependency sets are pinned in each app's `composer.lock`.

## Fairness — what is held identical, and what isn't

**Identical across all PHP‑FPM stacks** (the fairness invariants):

- One shared PHP image ([`docker/php`](./docker/php)): same PHP 8.5, same
  extensions, same OPcache (`validate_timestamps=0`, JIT disabled), same php‑fpm
  pool (`pm=static`, 16 workers).
- One shared nginx image + [config template](./docker/nginx/default.conf.template):
  only the fastcgi upstream name differs between stacks. The container web root is
  identical (`public/index.php`) because all three frameworks use a single front
  controller.
- SQLite with an identical `users` schema, seeded with one deterministic row
  (`id = 1`).
- Every framework in production config with caches warmed.

**Deliberate, documented differences** (because "as each framework ships" is the
honest comparison):

- **Laravel & Symfony bench routes are stateless** — no session, no CSRF. Laravel's
  routes are registered outside the web middleware group; Symfony starts a session
  only on read/write and the bench routes never touch it.
- **Doppar boots a session + CSRF token on every request** — this is a core service
  provider that cannot be disabled via config (`relaxablePaths` only skips CSRF
  *validation*, not `session_start()`). Doppar therefore has no first‑class stateless
  route, and this per‑request cost is part of what the numbers show. Two sub‑decisions,
  both made to be *fair to Doppar*:
  - **File session driver** (Doppar's default, and the driver the vendor benchmarked).
    We initially used the cookie driver and it turned out ~4.5× slower on `/db` — its
    per‑request encryption is a heavy path in Doppar — which would have unfairly
    buried it. The file driver is the honest "as it ships" choice.
  - **Sessions on tmpfs (RAM).** Because `wrk` sends no cookies, every request creates
    a *new* session file. On disk that becomes an inode/directory‑scaling artifact that
    does not reflect production (real clients reuse their session cookie), so the
    sessions directory is mounted on tmpfs and `bench/run.sh` clears it before each run.
    This measures Doppar's framework + session logic, not disk churn.
- **The worker stack** uses a different web server (see ¹ above).

## Caveats

- **Desktop hardware**, not a tuned server. Numbers are meaningful *relative to each
  other*, not as absolute production figures.
- **The load generator (`wrk`) runs on the same machine** as the stack under test,
  contending for CPU. The php‑fpm pool is capped at 16 workers (of 24 logical
  threads) to leave the generator headroom; this is identical for every stack.
- **Everything is containerized.** Docker networking and overlay filesystems add
  overhead versus bare metal — again, identical for every stack.
- Only one stack plus `wrk` runs at any moment (compose profiles enforce this).
- **Run‑to‑run variance on a shared desktop.** The same stack/endpoint/stage varies
  between rounds depending on what else the machine is doing (typically ~10–30% here;
  it was far worse during an earlier run when the host was heavily loaded). The
  interleaved scheduling and median mitigate this, and the `Spread (req/s)` column in
  [`RESULTS.md`](./RESULTS.md) shows the observed min–max per cell — the practical
  consequence is that **only clear differences between frameworks are meaningful;
  small gaps are within the noise.** For definitive numbers, re‑run on an
  otherwise‑idle machine.
- These are single‑session results on one machine; treat them as a reproducible
  data point, not the last word.

## Benchmark hosts

Two deliberately different machines — the relative ordering turned out to
depend on the hardware generation (see `RESULTS.md` for both sections):

```
desktop (bare metal)
  CPU     : 12th Gen Intel Core i9-12900K (8 P + 8 E cores, 24 logical threads)
  RAM     : 123 GiB DDR5-4000
  Storage : Kingston KC3000 2 TB NVMe SSD (LUKS-encrypted LVM)
  Kernel  : Linux 6.17
  Docker  : 29.6.2 / Compose v5.3.1

server (VMware VM, otherwise idle)
  CPU     : Intel Xeon E5-2690 v2 @ 3.00 GHz (2013 Ivy Bridge EP), 35 vCPUs
  RAM     : 189 GiB (DDR3-era Ivy Bridge EP host platform)
  Storage : VMware virtual disk backed by an Intel DC P3600 NVMe SSD
  Kernel  : Linux 5.15
  Docker  : 27.0.3 / Compose v2.28.1
```

The exact environment of each run is captured to `results/<host>/env.txt` by
`bench/run.sh`.

The full fairness contract — every setting per framework, with sources, plus
the notes from an adversarial self-audit of this setup — lives in
[FAIRNESS.md](FAIRNESS.md).

## Reproduce

Runs on any Linux host with only **Docker (Compose v2 plugin) and git** — PHP,
Composer, wrk and even the results generator run in containers; nothing else is
assumed on the host. One command does everything:

```bash
./bench.sh all      # build apps + benchmark every stack + write RESULTS.md + tear down (~45-60 min)
```

Sub-steps and single stacks are available too:

```bash
./bench.sh setup                 # build images + (re)create the apps
./bench.sh run                   # benchmark all stacks (apps must be set up)
./bench.sh laravel               # benchmark one stack (doppar-fpm|doppar-worker|laravel|symfony)
./bench.sh results               # regenerate RESULTS.md from results/*/
./bench.sh down                  # stop/remove all benchmark containers
```

Tunable via env vars, e.g. skip the experimental worker and do two rounds, or move
the host debug ports:

```bash
STACKS="doppar-fpm laravel symfony" REPEATS=2 ./bench.sh run
BENCH_PORT_BASE=19000 ./bench.sh all
```

Results are written **per host** to `results/<hostname>-<date>/`, so runs from
several machines (a laptop, a dedicated server, a NAS) coexist and appear as
separate sections in `RESULTS.md`. Full first-time instructions are in
[RUNBOOK.md](./RUNBOOK.md).

## Layout

```
bench.sh             one-command entrypoint (all | setup | run | <stack> | results | down)
docker/php/          shared PHP 8.5-fpm image (extensions, OPcache, pool)
docker/nginx/        shared nginx vhost template
docker/frankenphp/   FrankenPHP image + Caddyfile for the worker stack
docker/wrk/          wrk 4.2.0 built from source
apps/{doppar,laravel,symfony}/   the three applications (vendor/ gitignored)
bench/setup.sh       reproduce the apps from a clean checkout
bench/run.sh         drive warmup + load stages + repeats -> results/<host>/raw/
bench/gen_results.py per-host raw reports -> RESULTS.md (one section per host)
results/<host>/      raw wrk output + env.txt per machine (committed; part of the deliverable)
RUNBOOK.md           first-time "run this on your own machine" guide
```

## License

[MIT](./LICENSE) © 2026 Matthias Breddin.
