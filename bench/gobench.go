// Single-threaded timing for go-trafilatura, matching the Elixir and Python
// harnesses: read + parse + extract per document, warmup excluded.
//
// go-trafilatura's own comparison script parses every document before starting
// its timer, so its published durations are extract-only and not comparable.
//
// Not part of the Elixir build. To run it, drop it in its own module alongside
// a go-trafilatura checkout:
//
//	mkdir gobench && cp bench/gobench.go gobench/main.go && cd gobench
//	go mod init gobench
//	go mod edit -replace github.com/markusmobius/go-trafilatura=../go-trafilatura
//	go mod tidy && go run . ../go-trafilatura/test-files ../bench/comparison.json
package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	nurl "net/url"
	"path/filepath"
	"sort"
	"time"

	"github.com/go-shiori/dom"
	gt "github.com/markusmobius/go-trafilatura"
)

type Entry struct {
	URL  string `json:"url"`
	File string `json:"file"`
}

const warmup = 40

func find(corpus, name string) string {
	for _, d := range []string{"comparison", "mock"} {
		p := filepath.Join(corpus, d, name)
		if _, err := os.Stat(p); err == nil {
			return p
		}
	}
	return ""
}

func one(path, rawURL string, opts gt.Options) time.Duration {
	start := time.Now()
	b, err := os.ReadFile(path)
	if err == nil {
		if u, err := nurl.ParseRequestURI(rawURL); err == nil {
			opts.OriginalURL = u
		}
		if doc, err := dom.Parse(bytes.NewReader(b)); err == nil {
			func() {
				defer func() { recover() }()
				gt.ExtractDocument(doc, opts)
			}()
		}
	}
	return time.Since(start)
}

func main() {
	corpus, data := os.Args[1], os.Args[2]

	raw, err := os.ReadFile(data)
	if err != nil {
		panic(err)
	}
	var entries []Entry
	if err := json.Unmarshal(raw, &entries); err != nil {
		panic(err)
	}
	sort.Slice(entries, func(i, j int) bool { return entries[i].File < entries[j].File })

	var kept []Entry
	for _, e := range entries {
		if find(corpus, e.File) != "" {
			kept = append(kept, e)
		}
	}
	fmt.Printf("Documents: %d  workers: 1  warmup: %d\n", len(kept), warmup)

	variants := []struct {
		name string
		opts gt.Options
	}{
		{"go-trafilatura", gt.Options{EnableFallback: false, ExcludeComments: true, Focus: gt.Balanced}},
		{"go-trafilatura + Fallback", gt.Options{EnableFallback: true, ExcludeComments: true, Focus: gt.Balanced}},
		{"go-trafilatura + Favor Precision", gt.Options{EnableFallback: true, ExcludeComments: true, Focus: gt.FavorPrecision}},
		{"go-trafilatura + Favor Recall", gt.Options{EnableFallback: true, ExcludeComments: true, Focus: gt.FavorRecall}},
	}

	for _, v := range variants {
		for i := 0; i < warmup && i < len(kept); i++ {
			one(find(corpus, kept[i].File), kept[i].URL, v.opts)
		}
		lat := make([]time.Duration, 0, len(kept))
		total := time.Now()
		for _, e := range kept {
			lat = append(lat, one(find(corpus, e.File), e.URL, v.opts))
		}
		elapsed := time.Since(total)
		sort.Slice(lat, func(i, j int) bool { return lat[i] < lat[j] })
		median := lat[len(lat)/2]
		p95 := lat[min(int(0.95*float64(len(lat))), len(lat)-1)]
		fmt.Printf("%-32s total %7.3fs  median %7.2fms  p95 %8.2fms\n",
			v.name, elapsed.Seconds(), float64(median.Microseconds())/1000, float64(p95.Microseconds())/1000)
	}
}
