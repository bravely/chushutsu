"""Single-threaded timing for Python trafilatura, matching the Elixir harness:
read + parse + extract per document, with a warmup pass excluded."""
import json, sys, time, os, statistics
import trafilatura

CORPUS, DATA = sys.argv[1], sys.argv[2]
WARMUP = 40

VARIANTS = [
    ("trafilatura", dict(fast=True)),
    ("trafilatura + Fallback", dict()),
    ("trafilatura + Favor Precision", dict(favor_precision=True)),
    ("trafilatura + Favor Recall", dict(favor_recall=True)),
]

def find(name):
    for d in ("comparison", "mock"):
        p = os.path.join(CORPUS, d, name)
        if os.path.exists(p):
            return p

def one(entry, opts):
    path = find(entry["file"])
    t0 = time.perf_counter()
    text = ""
    if path:
        try:
            with open(path, "rb") as f:
                text = trafilatura.extract(f.read(), include_comments=False,
                                           include_tables=True, url=entry["url"], **opts) or ""
        except Exception:
            text = ""
    return (time.perf_counter() - t0) * 1000, text

def main():
    entries = sorted(json.load(open(DATA)), key=lambda e: e["file"])
    entries = [e for e in entries if find(e["file"])]
    print(f"Documents: {len(entries)}  workers: 1  warmup: {WARMUP}")
    for name, opts in VARIANTS:
        for e in entries[:WARMUP]:
            one(e, opts)
        t0 = time.perf_counter()
        lat = [one(e, opts)[0] for e in entries]
        total = time.perf_counter() - t0
        lat.sort()
        p95 = lat[min(int(0.95 * len(lat)), len(lat) - 1)]
        print(f"{name:32s} total {total:7.3f}s  median {statistics.median(lat):7.2f}ms  p95 {p95:8.2f}ms", flush=True)

if __name__ == "__main__":
    main()
