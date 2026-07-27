# Benchmark results

960 documents from the go-trafilatura annotated corpus. All three implementations
run on the same machine (Apple silicon, 10 cores), same corpus, same options
(`include_comments: false`, `include_tables: true`, URL supplied).

Versions: Chushutsu 0.1.0 (Elixir 1.20.2 / OTP 29), trafilatura 2.1.0 (Python
3.14), go-trafilatura at `main` (Go 1.26).

## Methodology

Two things had to be corrected before the numbers meant anything:

- **go-trafilatura's own comparison script parses every document *before* it
  starts its timer**, so its published durations are extract-only. Its CLI also
  defaults to a single worker. Quoting those figures against a full-pipeline
  measurement would have flattered it by roughly the cost of parsing.
- **Warmup matters on the BEAM and in CPython**: the JIT, and Chushutsu's lazily
  decompressed jusText stoplists, otherwise land entirely on whichever variant
  runs first.

So every implementation here is measured the same way: **single-threaded**,
**read + parse + extract + serialize per document**, with a 40-document warmup
excluded. The Go figures come from `bench/gobench.go`, a harness written to match
the Elixir and Python ones rather than from go-trafilatura's own script.

Per-document median and p95 are reported alongside total wall clock, because
they are unaffected by worker count and so survive comparison across
implementations with different concurrency models.

## Speed (single-threaded, full pipeline)

| Variant           | go-trafilatura      | trafilatura (Python) | Chushutsu (Elixir)   |
|-------------------|---------------------|----------------------|----------------------|
| standard          | 7.35 s / 6.4 ms     | 12.46 s / 9.2 ms     | 35.53 s / 26.1 ms    |
| + fallback        | 11.94 s / 9.7 ms    | 17.34 s / 12.6 ms    | 57.71 s / 42.1 ms    |
| + favor precision | 11.34 s / 9.1 ms    | 17.51 s / 14.1 ms    | 41.92 s / 32.1 ms    |
| + favor recall    | 10.28 s / 7.9 ms    | 11.77 s / 9.1 ms     | 38.49 s / 28.8 ms    |

*(total wall clock / median per document)*

Chushutsu is **2.4–3.3× slower than Python** and **3.7–4.8× slower than Go**.

### Where the time goes

Profiling the pipeline over a 240-document sample:

| Phase                          | Share |
|--------------------------------|-------|
| HTML parsing (html5ever, Rust) | 11.5% |
| Extraction (Elixir)            | 88.5% |

Parsing is not the bottleneck — the tree manipulation is. trafilatura gets its
tree operations from lxml (C) and go-trafilatura from native structs with real
pointers; `Chushutsu.Tree` is pure Elixir over an immutable map, so every
`put_tag`, `append` and `delete_element` is a map update rather than a pointer
write, and `deep_copy` genuinely rebuilds a subtree where lxml can memcpy.

This is a deliberate trade — the arena is what makes the port safe to reason
about and testable — but it is where the gap lives, and it is addressable
without changing behaviour if it ever matters.

## Speed (all cores)

The BEAM parallelizes in-process, so the wall-clock picture changes when work is
spread across schedulers:

| Variant           | 1 worker | 10 workers | speedup |
|-------------------|----------|------------|---------|
| standard          | 35.53 s  | 9.28 s     | 3.8×    |
| + fallback        | 57.71 s  | 14.79 s    | 3.9×    |
| + favor precision | 41.92 s  | 11.30 s    | 3.7×    |
| + favor recall    | 38.49 s  | 13.53 s    | 2.8×    |

Short of linear, as expected — allocation-heavy work on ten schedulers contends
for memory bandwidth and GC.

## Accuracy

Unchanged by any of the above; worker count and warmup do not affect output.

| Variant           | Precision | Recall | Accuracy | F-score   | trafilatura F | go-trafilatura F |
|-------------------|-----------|--------|----------|-----------|---------------|------------------|
| standard          | 0.920     | 0.909  | 0.915    | **0.915** | 0.913         | 0.904            |
| + fallback        | 0.921     | 0.921  | 0.921    | **0.921** | 0.920         | 0.915            |
| + favor precision | 0.937     | 0.894  | 0.917    | **0.915** | 0.913         | 0.910            |
| + favor recall    | 0.913     | 0.917  | 0.915    | **0.915** | 0.914         | 0.910            |

The go-trafilatura column is from its own comparison tool run on this machine,
and matches its published figures closely (0.904 / 0.915 / 0.910 / 0.910).

## Reproducing

```bash
# Chushutsu — single-threaded, matching the table above
MIX_ENV=prod mix chushutsu.eval --corpus path/to/go-trafilatura/test-files --workers 1

# Chushutsu — all cores
MIX_ENV=prod mix chushutsu.eval --corpus path/to/go-trafilatura/test-files

# go-trafilatura, comparable harness
# see the header of bench/gobench.go — it needs its own Go module
cd gobench && go run . path/to/go-trafilatura/test-files ../bench/comparison.json

# Python trafilatura
python bench/bench_python.py path/to/go-trafilatura/test-files bench/comparison.json
```
