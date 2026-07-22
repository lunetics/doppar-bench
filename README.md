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
  provider that cannot be disabled via config. Because `wrk` sends no cookies, a
  file session driver would write a brand‑new session file per request (a disk‑I/O
  artifact, not framework overhead), so Doppar uses the **cookie** session driver:
  the session/CSRF/encryption work still runs, on the CPU where it belongs. This is
  a real architectural difference — Doppar has no first‑class stateless route — and
  it is part of what the numbers show.
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
- **Run‑to‑run variance is high on a shared desktop.** The same stack/endpoint/stage
  can vary by up to ~2× between rounds depending on what else the machine is doing.
  The interleaved scheduling and median mitigate this, and the `Spread (req/s)`
  column in [`RESULTS.md`](./RESULTS.md) shows the observed min–max per cell — but
  the practical consequence is that **only large differences between frameworks are
  meaningful; small gaps are within the noise.** For definitive numbers, re‑run on
  an otherwise‑idle machine.
- These are single‑session results on one machine; treat them as a reproducible
  data point, not the last word.

## Benchmark host

```
CPU     : 12th Gen Intel Core i9-12900K (8 P-cores + 8 E-cores, 24 logical threads)
RAM     : 123 GiB
Kernel  : Linux 6.17.0-35-generic
Docker  : 29.6.2
Compose : v5.3.1
```

The exact environment of a given run is captured to `results/env.txt` by
`bench/run.sh`.

## Reproduce

Requires only Docker (with the Compose plugin). Nothing is installed on the host —
PHP, Composer and wrk all run in containers. Compose project name `doppar-bench`,
ports `18010`–`18040`.

```bash
# 1. Build the apps (composer install + migrate + seed + warm caches, all dockerized)
./bench/setup.sh

# 2. Run the full benchmark (~50 min; brings each stack up in turn, benches, tears down)
./bench/run.sh

# 3. Generate RESULTS.md from the raw wrk reports
python3 bench/gen_results.py
```

Tunable via env vars, e.g. skip the experimental worker and do two repeats:

```bash
STACKS="doppar-fpm laravel symfony" REPEATS=2 ./bench/run.sh
```

## Layout

```
docker/php/          shared PHP 8.5-fpm image (extensions, OPcache, pool)
docker/nginx/        shared nginx vhost template
docker/frankenphp/   FrankenPHP image + Caddyfile for the worker stack
docker/wrk/          wrk 4.2.0 built from source
apps/{doppar,laravel,symfony}/   the three applications (vendor/ gitignored)
bench/setup.sh       reproduce the apps from a clean checkout
bench/run.sh         drive warmup + load stages + repeats -> results/raw/
bench/gen_results.py raw reports -> RESULTS.md
results/raw/         raw wrk output (committed; part of the deliverable)
```

## License

[MIT](./LICENSE) © 2026 Matthias Breddin.
