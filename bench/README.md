# Scanner benchmark

Compares the production scanner approach (Foundation `contentsOfDirectory` +
`resourceValues`, gated concurrency — what `Scanner` in the app uses) against a
`getattrlistbulk` prototype that batches directory metadata in one syscall.

```sh
swiftc -O scan-bench.swift -o scan-bench
./scan-bench ~/Library/Developer     # deep single subtree
./scan-bench ~/workspace             # many small dirs (node_modules/.git)
```

Each run warms the cache, then times `fm` (Foundation) vs `bulk`
(getattrlistbulk) twice and prints the size delta (must be 0.00%).

## Findings (M-series, 11 cores, warm cache)

| Folder              | fm (current) | bulk   | speedup |
|---------------------|--------------|--------|---------|
| ~/Library/Developer | 0.36s        | 0.28s  | ~1.3×   |
| ~/workspace         | 5.6s         | 4.2s   | ~1.3×   |

Totals are byte-identical (0.00% diff). `bulk` is consistently ~1.3× faster but
costs ~70 lines of raw-pointer buffer parsing, so it's **not** in the app — the
win is modest and we're I/O/metadata-bound. Kept here as a reference for if we
ever need to scan million-file trees. See git history around this dir for the
discussion.
