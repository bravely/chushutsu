# Chushutsu

Extracts the main text, metadata and comments from a web page.

An Elixir port of [trafilatura](https://github.com/adbar/trafilatura), covering
extraction only. Fetching pages and discovering links are out of scope — you hand
it HTML you already have.

```elixir
{:ok, text} = Chushutsu.extract(html)
{:ok, text} = Chushutsu.extract(html, url: "https://news.test/post", output_format: :markdown)
{:ok, doc}  = Chushutsu.extract_with_metadata(html)
```

## Accuracy

Measured against the 960-document annotated corpus that
[go-trafilatura](https://github.com/markusmobius/go-trafilatura) uses, with its
scoring reproduced exactly: each page lists strings that must appear in the output
and strings that must not, and the counts are pooled across the corpus.

Python trafilatura 2.1.0 was run over the same corpus, on the same machine, with
the same options, as the reference:

| Variant           | Precision | Recall | Accuracy | F-score   | trafilatura F |
|-------------------|-----------|--------|----------|-----------|---------------|
| standard (fast)   | 0.920     | 0.909  | 0.915    | **0.915** | 0.913         |
| + fallback        | 0.921     | 0.921  | 0.921    | **0.921** | 0.920         |
| + favor precision | 0.937     | 0.894  | 0.917    | **0.915** | 0.913         |
| + favor recall    | 0.913     | 0.917  | 0.915    | **0.915** | 0.914         |

Per document, 941–945 of the 960 score *identically* to trafilatura depending on
the variant; the rest split roughly evenly in both directions. No document crashes
the extractor.

Reproduce it with a go-trafilatura checkout:

```bash
mix chushutsu.eval --corpus path/to/go-trafilatura/test-files
```

The corpus is ~150 MB of third-party HTML and is not vendored.
`bench/comparison.json` holds the annotations, converted from go-trafilatura's Go
source.

## How it works

Extraction is a cascade. Each stage engages only when the previous one came up
short, which keeps the output precise on conventional markup without giving up on
pages that have none:

1. **The rule-based extractor** locates the content area using trafilatura's
   class/id vocabulary, prunes boilerplate, and rewrites what's left into a small
   internal tag set. Includes a wild-text sweep for short results.
2. **Generic extractors** — [readability](lib/chushutsu/external/readability.ex)
   scores containers by the shape of their text, and
   [jusText](lib/chushutsu/external/justext.ex) classifies paragraphs by stopword
   and link density. Both ignore class names, so they reach content the rules walk
   past. Skipped with `fast: true`.
3. **A baseline dump** over the original tree: embedded JSON-LD (`articleBody`,
   recipe steps, FAQ answers, Discourse posts), `<article>` elements, then
   paragraph text.
4. **Recall escalation** when the result still covers little of the page, which
   usually means the layout isn't article-shaped rather than that the page is
   short.

### Notable implementation choices

**The tree.** trafilatura is written against lxml, so the port needs the same
primitives: `text`/`tail` splitting, parent pointers, and in-place rewiring during
a walk. [`Chushutsu.Tree`](lib/chushutsu/tree.ex) keeps nodes in a flat arena keyed
by integer id — every operation returns a new tree, so the structure stays
immutable, but parent and sibling lookups stay cheap and ids remain stable across
mutations. That last property is what lets the extractor collect a list of elements
and then rewrite them one at a time.

**Selectors.** The upstream XPath expressions lean on the EXSLT `re:test`
extension. Rather than ship an XPath engine,
[`Chushutsu.Selectors`](lib/chushutsu/selectors.ex) translates each into a
predicate. Two XPath quirks are preserved deliberately, because the heuristics are
calibrated around them: `@id|@class` tests only the attribute written first in the
source, and `translate(@class, 'CM', 'cm')` folds only the letters it lists.

**Encoding.** lxml sniffs legacy encodings; an HTML5 parser does not. 27 corpus
documents are windows-1252 or windows-1250, and without
[`Chushutsu.Encoding`](lib/chushutsu/encoding.ex) they failed to parse at all —
worth about 0.01 F-score on its own.

## Options

| Option                                                       | Default | |
|--------------------------------------------------------------|---------|---|
| `:output_format`                                             | `:txt`  | also `:markdown`, `:xml`, `:xmltei`, `:json`, `:csv`, `:html` |
| `:url`                                                       | `nil`   | absolutizes links, enriches metadata |
| `:fast`                                                      | `false` | skip the generic fallbacks |
| `:favor_precision` / `:favor_recall`                         | `false` | shift the balance |
| `:include_comments`                                          | `true`  | |
| `:include_tables`                                            | `true`  | |
| `:include_images` / `:include_links` / `:include_formatting` | `false` | |
| `:with_metadata`                                             | `false` | extract metadata and include it in the output |
| `:target_language`                                           | `nil`   | discard documents not in this language |
| `:deduplicate`                                               | `false` | drop segments already seen in this process |

## Differences from trafilatura

Three upstream behaviours are narrower here:

- **`:target_language`** filters on the page's *declared* language only.
  Upstream also classifies the extracted text with `py3langid`, catching pages
  that declare nothing or declare wrongly.
- **Date extraction** covers meta tags, JSON-LD, `<time>` elements and dates in
  the URL. Upstream delegates to `htmldate`, which searches far more aggressively.
- **`:tei_validation`** is accepted but performs no validation — there is no DTD
  validator in the Erlang standard library. TEI output is still produced and
  structurally repaired.

None of these affect the accuracy measured above, which does not exercise them.

## Installation

```elixir
def deps do
  [{:chushutsu, "~> 0.1.0"}]
end
```

## Tests

```bash
mix test
CHUSHUTSU_CORPUS=path/to/go-trafilatura/test-files mix test   # adds the accuracy guard
```

## Licence and attribution

Apache-2.0, matching trafilatura. This port derives from:

- [trafilatura](https://github.com/adbar/trafilatura) by Adrien Barbaresi (Apache-2.0)
- readability-lxml, via trafilatura's fork, ultimately arc90's Readability (Apache-2.0)
- [jusText](https://github.com/miso-belica/jusText) by Jan Pomikálek (BSD-2-Clause) —
  algorithm and the bundled stoplists in `priv/`
- The evaluation corpus annotations come from
  [go-trafilatura](https://github.com/markusmobius/go-trafilatura) (Apache-2.0)
