# Benchmarks

```
zig build bench
```

The benchmark (built in `ReleaseFast`) runs against a single dataset size — 1000 entries by default — and reports four things:

- **Operation latency** — per-operation latency percentiles (p50/p90/p99/p99.9/max) for point lookups inside a long-lived read transaction, point lookups with a fresh transaction per op, and durable single-key commits. Percentiles, not mean ± stddev, because latency is heavily right-skewed and the tail is what matters. Each sample includes one system-clock read (~100–200ns), which sets the p50 floor for sub-microsecond reads — see the concurrency table for clock-free per-get throughput.
- **Throughput** — full cursor scans, same-size overwrites (the cheap write path), and inserts of brand-new keys in ascending vs. random order. The ascending/random gap is the cost of B+tree page splits as a dataset grows.
- **Concurrent reads** — aggregate read throughput as reader threads scale up, demonstrating LMDB's lock-free MVCC readers.
- **Storage** — page counts, tree depth, and bytes-per-entry after loading, i.e. on-disk space efficiency.

Durable commits fsync on every transaction (LMDB's default), so that row is bound by the storage device's fsync latency, not by LMDB; the bulk-write throughput rows amortize one fsync over the whole batch.

The dataset size, key size, and value size are all build options — for example, one million entries with 16-byte keys and 64-byte values:

```
zig build bench -Dentries=1000000 -Dkey-size=16 -Dvalue-size=64
```

- `-Dentries=N` — number of entries in the dataset (default 1000). Larger datasets deepen the B+tree and push reads out of cache.
- `-Dvalue-size=N` — value payload bytes (default 32). Values large enough to exceed roughly half a page (~8 KiB with the 16 KiB pages here) spill onto LMDB overflow pages, a separate code path these benchmarks don't exercise.
- `-Dkey-size=N` — key bytes, **4 to 511** (default 4). Keys encode a `u32` index in their leading bytes, so the minimum is 4; the maximum is LMDB's default `MDB_MAXKEYSIZE` of 511. Out-of-range values are a compile error.

To debug the harness itself, override the optimize mode with `-Dbench-optimize=Debug`.

The runs below were recorded on an M3 MacBook Air.

## 1000 entries (key 4B, value 32B)

**Operation latency** (microseconds)

|                              | samples |    p50 |    p90 |     p99 |   p99.9 |     max |
| :--------------------------- | ------: | -----: | -----: | ------: | ------: | ------: |
| get (shared read txn)        |  100000 |  0.084 |  0.125 |   0.125 |   0.208 |  10.500 |
| get (new read txn per op)    |  100000 |  0.125 |  0.167 |   0.208 |   0.250 |  12.542 |
| durable commit (1 write/txn) |    2000 | 70.959 | 87.300 | 106.084 | 147.614 | 179.000 |

**Throughput** (operations/second)

|                                          | ops / s |
| :--------------------------------------- | ------: |
| full scan (cursor)                       |    118M |
| overwrite all keys, random order (1 txn) |   4.00M |
| insert new keys, ascending (1 txn)       |   5.61M |
| insert new keys, random order (1 txn)    |   4.52M |

**Concurrent reads** (8 CPUs available)

| threads | total reads/s | per-thread/s | scaling |
| ------: | ------------: | -----------: | ------: |
|       1 |         10.8M |        10.8M |   1.00x |
|       2 |         20.7M |        10.4M |   1.91x |
|       4 |         40.3M |        10.1M |   3.72x |
|       8 |         53.0M |        6.62M |   4.89x |

**Storage** (after loading 1000 entries)

| page size | depth | branch | leaf | overflow | data (KiB) | bytes/entry |
| --------: | ----: | -----: | ---: | -------: | ---------: | ----------: |
|     16384 |     2 |      1 |    3 |        0 |       64.0 |        65.5 |

## 1000000 entries (key 4B, value 32B)

**Operation latency** (microseconds)

|                              | samples |    p50 |     p90 |     p99 |   p99.9 |     max |
| :--------------------------- | ------: | -----: | ------: | ------: | ------: | ------: |
| get (shared read txn)        |  100000 |  0.584 |   0.917 |   1.417 |   1.958 |  10.709 |
| get (new read txn per op)    |  100000 |  0.583 |   0.792 |   1.042 |   1.375 |  10.958 |
| durable commit (1 write/txn) |    2000 | 98.792 | 110.421 | 122.625 | 189.011 | 441.792 |

**Throughput** (operations/second)

|                                          | ops / s |
| :--------------------------------------- | ------: |
| full scan (cursor)                       |   85.0M |
| overwrite all keys, random order (1 txn) |   1.66M |
| insert new keys, ascending (1 txn)       |   5.25M |
| insert new keys, random order (1 txn)    |   1.97M |

**Concurrent reads** (8 CPUs available)

| threads | total reads/s | per-thread/s | scaling |
| ------: | ------------: | -----------: | ------: |
|       1 |         1.86M |        1.86M |   1.00x |
|       2 |         3.88M |        1.94M |   2.09x |
|       4 |         7.42M |        1.85M |   3.99x |
|       8 |         9.98M |        1.25M |   5.37x |

**Storage** (after loading 1000000 entries)

| page size | depth | branch | leaf | overflow | data (KiB) | bytes/entry |
| --------: | ----: | -----: | ---: | -------: | ---------: | ----------: |
|     16384 |     3 |      4 | 2825 |        0 |    45264.0 |        46.4 |
