# Scan performance log

Loop-maintained record of optimization ideas and their measured impact.
Benchmark: `make bench` (full cross-tool) or `./bench/bench --quick ~/Library`
(Diskly-only, warm cache, best of 3). Machine-local numbers — compare only
against entries from the same machine/path. Run-to-run variance on this
machine is large (background system activity); trust interleaved A/B
best-of-N minimums, not single runs.

## Baseline (2026-07-01, ~/Library: 849k items, 103.9 GB, 11 cores)

- Original scanner (full-path `open()` per dir, `stat()` per dir in
  DirRegistry): **best 11.5–16.8s** across sessions.
- `sample`-profile of a scan: nearly all worker-thread time blocked in the
  `open()` syscall inside `Scanner.entries` — not getattrlistbulk, not CPU.

## Ideas tried

| # | Idea | Result | Verdict |
|---|------|--------|---------|
| 1 | `setiopolicy_np` dataless-off (never materialize iCloud files during scan) | No measurable delta (noise ±50%), but correctness win — scanner must not trigger downloads | KEEP |
| 2 | `openat(2)` recursion: hold parent dir fd, open children by single component; `fstat(fd)` in DirRegistry instead of full-path `stat()`; RLIMIT_NOFILE→10240 | Interleaved A/B: A best 11.51/11.79s vs B best **6.34/8.58s** → **~1.5–1.8×** | KEEP — landed in Scanner.swift + Model.swift + bench.swift |
| 3 | `--quick` bench mode (Diskly-only, best-of-3) | Tooling, not perf — makes iteration cheap | KEEP |
| 4 | Skip `withTaskGroup` for leaf dirs (no subdirs) and single-subdir chains (recurse inline) | Best 3.98/4.77s vs 4.13/6.65s — ~4%, matches the ~6% of profile samples in group machinery; within noise but structurally free | KEEP — landed in Model.swift + bench.swift |
| 5 | getattrlistbulk buffer 64 KiB / 1 MiB (vs 256 KiB) | All variants hit the same ~4.2–4.5s floor — no signal | NO EFFECT — stay at 256 KiB |
| 6 | ScanGate limit 2×cores | 4.10/4.33s vs 4.34/4.54s — no signal | NO EFFECT — stay at cores |
| 7 | Lazy FileNode.url (app only; derive URL from parent chain on demand, id → ObjectIdentifier, marks keyed by identity, registry path threaded as string) | Micro-bench: eager URL+path = 1.50s CPU per 850k nodes vs 0.09s string concat (16×); also drops ~850k retained URL objects (~100+ MB). Invisible to bench/bench (its Node has no URL) — app-side win only | KEEP — landed in Model.swift + TreemapView.swift; Release build OK |

## Post-openat profile (2026-07-02)

`sample` of bench_b: time now dominated by the necessary syscalls —
getattrlistbulk (395 leaf samples) and openat (~330) — plus withTaskGroup
machinery (255, addressed by idea 4) and String alloc/append traffic
(~100 across String(cString:), path concat, swift_allocObject). The scan is
now essentially syscall-bound; remaining ideas are second-order.

## Final cross-tool numbers (2026-07-02, make bench, ~/Library 849k items)

| tool | time | vs Diskly |
|---|---|---|
| Diskly | 12.31s (single shot; best-of-3 floor is ~4.1s) | 1.00× |
| du -sk | 25.35s | 2.06× |
| ncdu -1 -o - | 30.44s | 2.47× |
| find + stat | 39.01s | 3.17× |

## Loop concluded (2026-07-02)

Scan is syscall-bound: openat + getattrlistbulk per directory is the
necessary kernel work. Best-of-3 went from 11.5–16.8s → ~4.1s (~3–4×).
Remaining CPU-side ideas (lock traffic, string interning) each measure
below the machine's noise floor — not worth the complexity.

**Open items for a human:**
1. GUI smoke test after the FileNode identity change (scan, select, mark,
   Quick Look, "Other" aggregate) — the loop's attempt hit a locked screen.
2. Review + commit the working-tree changes (Scanner.swift, Model.swift,
   TreemapView.swift, bench/bench.swift, this file).

## Ideas rejected as below noise / not worth it

- ScanProgress/itemCount lock traffic (already per-dir).
- Benchmark variance hunt: same binary swings 4–24s with a stable ~4.1s
  floor and recurring ~7.5s/~12s modes — external contention (mds etc.).
