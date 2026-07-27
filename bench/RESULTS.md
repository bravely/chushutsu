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

| Variant           | go-trafilatura   | trafilatura (Python) | Chushutsu (Elixir) |
|-------------------|------------------|----------------------|--------------------|
| standard          | 7.35 s / 6.4 ms  | 12.46 s / 9.2 ms     | 29.60 s / 21.4 ms  |
| + fallback        | 11.94 s / 9.7 ms | 17.34 s / 12.6 ms    | 43.68 s / 31.7 ms  |
| + favor precision | 11.34 s / 9.1 ms | 17.51 s / 14.1 ms    | 33.58 s / 26.4 ms  |
| + favor recall    | 10.28 s / 7.9 ms | 11.77 s / 9.1 ms     | 29.88 s / 22.7 ms  |

*(total wall clock / median per document)*

Chushutsu is **1.9–2.6× slower than Python** and **2.9–4.2× slower than Go**.

Run-to-run variance on these totals is roughly ±3%, so differences smaller than
that are noise.

## Profiling pass

An `:eprof` run over a 60-document sample found three costs that were not
inherent to the design, all since removed. Output is byte-identical before and
after across all 960 documents and all four variants.

| Fix | Was |
|-----|-----|
| `Text.trim/1` rewritten as a code-point scan over binary slices | a compiled regex per call — `String.replace` plus its UTF-8 revalidation came to ~20% of runtime, and `trim` runs on nearly every element |
| Readability's div promotion checks tags directly | it serialized every div's subtree to HTML just to regex-test for block tags; the escaping alone was ~7% |
| Hot lists resolved at compile time, `Keyword.get` off the hot paths | `Settings.*()` rebuilt lists per element, which also forced `in` to compile to `lists:member/2` |
| Control characters stripped with a binary pattern; encoding validated with `String.valid?/2` in `:fast_ascii` mode | two full-document UTF-8 validations per page, one of them redundant, plus a regex over the whole document — 15.8% of the parse path between them |

Gains: standard 16.7%, fallback 24.3%, precision 19.9%, recall 22.4%. The
fallback variants gain most because the readability fix only applies there.

### A caveat on reading eprof

eprof traces every call, so a function invoked 15M times at 0.04 µs each has its
attributed share dominated by tracing overhead. It reported 8.84% for the
document-level UTF-8 validation; a direct A/B put the real figure near 1%. Two
lessons, both learned the hard way here: trust the *ranking*, not the
percentages, and confirm every fix with a wall-clock A/B. The call *counts* are
reliable, and a count that does not move after a supposed fix is the tell —
that is what exposed the misattribution.

### What remains

Roughly in order, from a re-profile: `maps:put`/`update_node` (tree mutation),
`Text.len` code-point counting, `Tree.do_iter` list building, and `lists:member`
from `tag in potential_tags` where the list is genuinely dynamic.

None of that is a single hotspot any more — it is the spread cost of the arena.
trafilatura gets its tree operations from lxml (C) and go-trafilatura from
native structs with real pointers, while `Chushutsu.Tree` is pure Elixir over an
immutable map: every `put_tag`, `append` and `delete_element` is a map update
rather than a pointer write. That is the deliberate trade that makes the port
safe to reason about and testable, and closing the rest of the gap would mean
reconsidering it.

Parsing is not the bottleneck: html5ever accounts for 11.5% of the pipeline.

## Speed (all cores)

The BEAM parallelizes in-process, so the wall-clock picture changes when work is
spread across schedulers:

| Variant           | 1 worker | 10 workers | speedup |
|-------------------|----------|------------|---------|
| standard          | 31.07 s  | 5.38 s     | 5.8×    |
| + fallback        | 44.30 s  | 7.66 s     | 5.8×    |
| + favor precision | 32.86 s  | 5.54 s     | 5.9×    |
| + favor recall    | 29.44 s  | 5.52 s     | 5.3×    |

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
