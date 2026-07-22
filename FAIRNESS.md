# Fairness contract

What "fair" means in this benchmark, every setting that matters, and the notes
from an adversarial self-audit (2026-07-22) that actively tried to find
misconfiguration working *against* Doppar.

The principle: **identical shared layers, and each framework at its own
vendor-documented production best practice.** No hand-tuning beyond what each
vendor's docs recommend, and no disabling of features a framework cannot
disable through documented configuration.

## Shared infrastructure (identical for all stacks)

| Layer | Setting | Value |
|---|---|---|
| PHP | image | one shared `php:8.5.8-fpm-alpine` build, same extensions |
| OPcache | enabled | yes (verified at runtime via FPM probe: `opcache_enabled: true`) |
| OPcache | `validate_timestamps` | `0` |
| OPcache | JIT | disabled for all stacks (verified: `jit: false`) |
| PHP-FPM | pool | `pm = static`, 16 workers, `max_requests = 0` |
| Web server | nginx | one shared image + vhost template; only the fastcgi upstream name differs |
| Database | SQLite | identical `users` schema, one deterministic seeded row |
| Load | wrk stages | `2t/50c/20s`, `4t/200c/30s`, `8t/500c/60s` (the vendor's own stages) |
| Warmup | discarded | 6 s wrk warmup per endpoint per round (thousands of requests — fills all 16 workers), never measured |
| Scheduling | interleaved | every round runs all stacks once; 6 s cooldown between runs; median of 3 rounds reported; raw reports committed |

## Per-framework production configuration (with sources)

**Doppar 3.26.5**

| Setting | Value | Why |
|---|---|---|
| `APP_ENV` | `production` | docs deployment guidance (skeleton default is `local`) |
| `APP_DEBUG` | `false` | docs: "it is crucial to set the APP_DEBUG variable to false" in production |
| `APP_ROUTE_CACHE` | `true` | docs: default `false` "disables route caching. … in a production environment, you should set APP_ROUTE_CACHE=true" |
| caches | `config:cache` + `route:cache` at setup | the docs' `php pool boost` bundle minus `view:cache` (no views are rendered on either bench endpoint) |
| `SESSION_DRIVER` | `file` | Doppar's shipped default; the cookie driver measured ~4.5x slower on `/db` and was rejected as unfair to Doppar |
| sessions dir | tmpfs, cleared per run | a cookieless load generator creates a new session file per request; on-disk accumulation is a bench artifact, not a framework property |

**Laravel 13.21.1**

| Setting | Value | Why |
|---|---|---|
| `APP_ENV` / `APP_DEBUG` | `production` / `false` | Laravel production baseline |
| caches | `config:cache` + `route:cache` | documented deployment optimization |
| bench routes | registered outside the `web` middleware group (stateless, no session/CSRF) | Laravel's documented pattern for stateless endpoints |

**Symfony 8.1.1 (framework-bundle)**

| Setting | Value | Why |
|---|---|---|
| `APP_ENV` | `prod` (+ `composer dump-env prod`) | Symfony production baseline |
| caches | `cache:clear` + `cache:warmup` | documented deployment optimization |
| bench routes | plain controllers, no session started | Symfony sessions start lazily; these endpoints never touch one |

## Why Doppar carries session cost and the others do not

Doppar's `SessionServiceProvider` is a hardcoded core provider
(`Application::loadCoreProviders()`); as of 3.26.5 there is no null/array
session driver and no documented per-route opt-out — `relaxablePaths` skips
CSRF *validation*, not `session_start()`. A minimal Doppar endpoint therefore
performs, on every cookieless request: a session start, a session ID
regeneration, and a session-file write. Laravel and Symfony both offer
documented stateless routes and pay none of this. Keeping the session is not a
bench decision; it is what Doppar ships. If a future Doppar release adds a
documented way to disable sessions per route, this benchmark will add that row.

## Adversarial self-audit notes (2026-07-22)

- **CSRF does not run on the bench routes.** Runtime probe: responses carry a
  `doppar_session` cookie but no `XSRF-TOKEN` cookie — the CSRF middleware
  never executes here. Doppar's per-request overhead on these routes is
  session work (plus a `_token` written into the session), not CSRF
  verification.
- **Config-cache revalidation is a real per-request Doppar cost.** As of
  3.26.5, `Config::loadFromCache()` re-hashes every config file and `.env`
  (`md5_file` + `filemtime`) on each request, while Laravel and Symfony load
  their production caches without revalidation. Inherent framework behavior;
  kept as shipped.
- **`APP_DEBUG` string-cast quirk (documented so nobody suspects debug skew):**
  Doppar's `env()` returns raw strings and `config/app.php` casts
  `(bool) "false"` to `true` in the cached config. Nothing reads
  `config('app.debug')` on the hot path, and the error handler compares the
  raw env string (`=== "true"`), so runtime behavior is production. This
  affects any Doppar deployment, not just this bench.
- **OPcache verified live for all stacks** (FPM probe through nginx:
  `opcache_enabled: true`, JIT off, scripts cached), and the FrankenPHP worker
  runs without a JIT advantage over the FPM stacks.
- **Symmetry:** all three apps installed with `composer install --no-scripts`,
  none with `--optimize-autoloader` or preloading; config/route caches
  verified effective at runtime for Doppar (cache files present in the running
  container, `APP_ROUTE_CACHE` honored by the router).

## What the vendor documents about his own benchmark

For contrast: the published Doppar benchmark (docs "Benchmark Snapshot")
documents nginx + PHP-FPM + PHP 8.5, SQLite, wrk stages and the route — and
does not document hardware, OPcache/JIT status, session driver, debug mode, or
whether the production caches above were active. This benchmark holds itself
to the stricter standard of applying and documenting all of them.
