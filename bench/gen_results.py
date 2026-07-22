#!/usr/bin/env python3
"""Generate RESULTS.md from the per-host benchmark directories under results/.

Layout (one directory per machine + date):

    results/<hostname>-<date>/
        env.txt              captured environment for that run
        raw/                 one wrk report per file:
            {stack}__{endpoint}__t{T}c{C}d{D}__run{R}.txt

Each host directory becomes its own section in RESULTS.md, so runs from several
machines coexist and are compared side by side. Within a section we group by
(stack, endpoint, stage), report the MEDIAN requests/sec across the repeats and —
for the run that produced that median — its average latency and error counts.
Min/max req/s across repeats are shown too so the spread is visible.
"""
from __future__ import annotations
import glob
import os
import re
import statistics
from collections import defaultdict

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RESULTS = os.path.join(ROOT, "results")

STACK_ORDER = ["doppar-fpm", "laravel", "symfony", "doppar-worker"]
STACK_LABEL = {
    "doppar-fpm": "Doppar (PHP-FPM)",
    "laravel": "Laravel (PHP-FPM)",
    "symfony": "Symfony (PHP-FPM)",
    "doppar-worker": "Doppar (FrankenPHP worker) ¹",
}
ENDPOINT_ORDER = ["json", "db"]
ENDPOINT_LABEL = {"json": "/json (static JSON)", "db": "/db (ORM primary-key lookup)"}
STAGE_ORDER = [(2, 50, 20), (4, 200, 30), (8, 500, 60)]

FNAME = re.compile(r"^(?P<stack>.+?)__(?P<ep>json|db)__t(?P<t>\d+)c(?P<c>\d+)d(?P<d>\d+)__run(?P<r>\d+)\.txt$")


def parse_report(path: str):
    txt = open(path, encoding="utf-8", errors="replace").read()
    out = {"rps": None, "lat_ms": None, "non2xx": 0, "sock": 0}
    m = re.search(r"^Requests/sec:\s*([\d.]+)", txt, re.M)
    if m:
        out["rps"] = float(m.group(1))
    m = re.search(r"^\s*Latency\s+([\d.]+)(us|ms|s)\b", txt, re.M)
    if m:
        v, u = float(m.group(1)), m.group(2)
        out["lat_ms"] = v / 1000 if u == "us" else (v * 1000 if u == "s" else v)
    m = re.search(r"Non-2xx or 3xx responses:\s*(\d+)", txt)
    if m:
        out["non2xx"] = int(m.group(1))
    m = re.search(r"Socket errors:.*?connect (\d+), read (\d+), write (\d+), timeout (\d+)", txt)
    if m:
        out["sock"] = sum(int(x) for x in m.groups())
    return out


def fmt_lat(ms):
    if ms is None:
        return "n/a"
    return f"{ms:.1f} ms" if ms >= 1 else f"{ms*1000:.0f} µs"


def fmt_err(non2xx, sock):
    if non2xx == 0 and sock == 0:
        return "0"
    parts = []
    if non2xx:
        parts.append(f"{non2xx} non-2xx")
    if sock:
        parts.append(f"{sock} socket")
    return ", ".join(parts)


def median_record(recs):
    recs = sorted(recs, key=lambda x: x["rps"])
    med_rps = statistics.median(r["rps"] for r in recs)
    rep = recs[len(recs) // 2]  # representative run (middle by rps)
    return med_rps, rep, recs[0]["rps"], recs[-1]["rps"]


def find_host_dirs():
    """Return [(tag, raw_dir, env_file)] for every per-host results directory,
    plus the legacy top-level results/raw/ if it still exists."""
    hosts = []
    for d in sorted(glob.glob(os.path.join(RESULTS, "*", ""))):
        raw = os.path.join(d, "raw")
        if glob.glob(os.path.join(raw, "*.txt")):
            hosts.append((os.path.basename(os.path.normpath(d)), raw, os.path.join(d, "env.txt")))
    legacy_raw = os.path.join(RESULTS, "raw")
    if glob.glob(os.path.join(legacy_raw, "*.txt")):
        hosts.append(("(legacy)", legacy_raw, os.path.join(RESULTS, "env.txt")))
    return hosts


def render_host(tag, raw_dir, env_file):
    grouped = defaultdict(list)
    for path in glob.glob(os.path.join(raw_dir, "*.txt")):
        m = FNAME.match(os.path.basename(path))
        if not m:
            continue
        rec = parse_report(path)
        if rec["rps"] is None:
            continue
        grouped[(m["stack"], m["ep"], (int(m["t"]), int(m["c"]), int(m["d"])))].append(rec)

    stacks_present = [s for s in STACK_ORDER if any(k[0] == s for k in grouped)]
    stacks_present += sorted({k[0] for k in grouped} - set(STACK_ORDER))

    L = [f"## Host: `{tag}`", ""]
    if os.path.exists(env_file):
        L += ["```", open(env_file, encoding="utf-8").read().strip(), "```", ""]

    for ep in ENDPOINT_ORDER:
        if not any(k[1] == ep for k in grouped):
            continue
        L.append(f"### {ENDPOINT_LABEL.get(ep, ep)}")
        L.append("")
        L.append("| Stack | " + " | ".join(f"{t}t / {c}c / {d}s" for (t, c, d) in STAGE_ORDER) + " |")
        L.append("|" + "---|" * (len(STAGE_ORDER) + 1))
        for stack in stacks_present:
            cells = []
            for stage in STAGE_ORDER:
                recs = grouped.get((stack, ep, stage))
                cells.append(f"**{median_record(recs)[0]:,.0f}** req/s" if recs else "–")
            L.append(f"| {STACK_LABEL.get(stack, stack)} | " + " | ".join(cells) + " |")
        L.append("")

    L.append("<details><summary>Detailed metrics (median req/s, latency, errors, spread)</summary>")
    L.append("")
    L.append("| Stack | Endpoint | Stage (t/c/d) | Median req/s | Avg latency | Errors | Spread (req/s) |")
    L.append("|---|---|---|---|---|---|---|")
    for stack in stacks_present:
        for ep in ENDPOINT_ORDER:
            for stage in STAGE_ORDER:
                recs = grouped.get((stack, ep, stage))
                if not recs:
                    continue
                med, rep, lo, hi = median_record(recs)
                t, c, d = stage
                L.append(
                    f"| {STACK_LABEL.get(stack, stack)} | /{ep} | {t}/{c}/{d}s | "
                    f"{med:,.0f} | {fmt_lat(rep['lat_ms'])} | {fmt_err(rep['non2xx'], rep['sock'])} | "
                    f"{lo:,.0f}–{hi:,.0f} |"
                )
    L.append("")
    L.append("</details>")
    L.append("")
    return "\n".join(L)


def main() -> int:
    hosts = find_host_dirs()
    if not hosts:
        print("No result directories found under results/. Run ./bench.sh all first.")
        return 1

    out = ["# Benchmark Results", ""]
    out.append("Median requests/sec across repeats, per stack × endpoint × load stage, "
               "for each machine the benchmark has been run on. Generated by "
               "`bench/gen_results.py` from the raw wrk reports under `results/<host>/raw/`.")
    out.append("")
    out.append("¹ **Doppar (FrankenPHP worker)** is experimental and NOT a controlled comparison: "
               "it swaps nginx+php-fpm for FrankenPHP/Caddy, so it changes the web server AND the "
               "runtime model at once. Read it as “can Doppar run as a persistent worker, and roughly "
               "how fast”, not as a like-for-like row against the PHP-FPM stacks. See README.")
    out.append("")
    for tag, raw_dir, env_file in hosts:
        out.append(render_host(tag, raw_dir, env_file))

    out_path = os.path.join(ROOT, "RESULTS.md")
    open(out_path, "w", encoding="utf-8").write("\n".join(out))
    print(f"Wrote {out_path} ({len(hosts)} host run(s): {', '.join(h[0] for h in hosts)}).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
