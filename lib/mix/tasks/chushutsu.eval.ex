defmodule Mix.Tasks.Chushutsu.Eval do
  @shortdoc "Scores extraction accuracy against the annotated comparison corpus"

  @moduledoc """
  Measures extraction accuracy against the annotated corpus used by
  go-trafilatura, reproducing its scoring exactly so the numbers are comparable.

  Each annotated page lists strings that must appear in the extracted text
  (`with`) and strings that must not (`without`). A `with` string found is a
  true positive, one missing a false negative; a `without` string found is a
  false positive, one absent a true negative. Precision, recall, accuracy and
  F-score are then computed over the pooled counts across the whole corpus.

  ## Usage

      mix chushutsu.eval --corpus path/to/go-trafilatura/test-files

  The corpus is not vendored: it is ~150 MB of third-party annotated HTML. Point
  `--corpus` at a go-trafilatura checkout's `test-files` directory, which must
  contain `comparison/` and `mock/` subdirectories.

  ## Options

    * `--corpus` — path to the test-files directory (required)
    * `--data` — annotations JSON (default `bench/comparison.json`)
    * `--variant` — run one variant only; repeatable. One of `standard`,
      `fallback`, `precision`, `recall`
    * `--limit` — score only the first N documents, for a quick check
    * `--report` — write per-document results to this path as JSON, for
      diffing runs or finding regressions
  """

  use Mix.Task

  @variants [
    {"Chushutsu", [fast: true]},
    {"Chushutsu + Fallback", []},
    {"Chushutsu + Favor Precision", [favor_precision: true]},
    {"Chushutsu + Favor Recall", [favor_recall: true]}
  ]

  @variant_names %{
    "standard" => "Chushutsu",
    "fallback" => "Chushutsu + Fallback",
    "precision" => "Chushutsu + Favor Precision",
    "recall" => "Chushutsu + Favor Recall"
  }

  @impl Mix.Task
  def run(argv) do
    {opts, _rest} =
      OptionParser.parse!(argv,
        strict: [corpus: :string, data: :string, variant: :keep, limit: :integer, report: :string]
      )

    Mix.Task.run("app.start")

    corpus = opts[:corpus] || Mix.raise("--corpus is required (path to go-trafilatura test-files)")
    entries = load_entries(opts[:data] || "bench/comparison.json", corpus, opts[:limit])

    Mix.shell().info("Documents: #{length(entries)}\n")

    results =
      entries
      |> run_variants(selected_variants(opts))
      |> tap(&print_table/1)

    if path = opts[:report], do: write_report(path, results)
  end

  defp selected_variants(opts) do
    case Keyword.get_values(opts, :variant) do
      [] ->
        @variants

      names ->
        wanted = Enum.map(names, &(Map.get(@variant_names, &1) || Mix.raise("unknown variant #{&1}")))
        Enum.filter(@variants, fn {name, _} -> name in wanted end)
    end
  end

  # ## Corpus --------------------------------------------------------------

  defp load_entries(data_path, corpus, limit) do
    data_path
    |> File.read!()
    |> Jason.decode!()
    |> Enum.sort_by(& &1["file"])
    |> then(&if(limit, do: Enum.take(&1, limit), else: &1))
    |> Enum.flat_map(&resolve_entry(&1, corpus))
  end

  defp resolve_entry(entry, corpus) do
    case find_file(corpus, entry["file"]) do
      nil ->
        Mix.shell().error("missing corpus file: #{entry["file"]}")
        []

      path ->
        [%{url: entry["url"], file: entry["file"], path: path, with: entry["with"], without: entry["without"]}]
    end
  end

  defp find_file(corpus, name) do
    Enum.find_value(["comparison", "mock"], fn dir ->
      path = Path.join([corpus, dir, name])
      if File.exists?(path), do: path
    end)
  end

  # ## Running -------------------------------------------------------------

  defp run_variants(entries, variants) do
    Enum.map(variants, fn {name, opts} ->
      Mix.shell().info("running #{name}…")
      started = System.monotonic_time(:millisecond)

      per_document =
        entries
        |> Task.async_stream(&score_document(&1, opts),
          timeout: :infinity,
          max_concurrency: System.schedulers_online(),
          ordered: false
        )
        |> Enum.map(fn {:ok, result} -> result end)

      elapsed = (System.monotonic_time(:millisecond) - started) / 1000
      report_failures(per_document)
      %{name: name, seconds: elapsed, totals: pool(per_document), documents: per_document}
    end)
  end

  # Crashes are bugs, not scores. Surfacing them keeps a regression from hiding
  # as a quiet drop in recall.
  defp report_failures(results) do
    failures = Enum.reject(results, &(&1.failure == nil or String.starts_with?(&1.failure, "error:")))

    if failures != [] do
      Mix.shell().error("  #{length(failures)} document(s) failed:")

      failures
      |> Enum.take(10)
      |> Enum.each(&Mix.shell().error("    #{&1.file}: #{&1.failure}"))
    end
  end

  # Matches go-trafilatura's comparison run: comments excluded, tables kept.
  defp score_document(entry, opts) do
    options = Keyword.merge([include_comments: false, include_tables: true, url: entry.url], opts)

    {text, failure} =
      case File.read(entry.path) do
        {:ok, html} -> safe_extract(html, options)
        {:error, reason} -> {"", "read: #{inspect(reason)}"}
      end

    entry
    |> evaluate(text)
    |> Map.merge(%{file: entry.file, extracted: String.length(text), failure: failure})
  end

  # A crash on one page must not abort a 900-page run, but it must not be
  # confused with a page that legitimately has no article on it either — an
  # empty result and a raise score the same, so the reason is recorded.
  defp safe_extract(html, options) do
    case Chushutsu.extract(html, options) do
      {:ok, text} -> {text, nil}
      {:error, reason} -> {"", "error: #{inspect(reason)}"}
    end
  rescue
    error -> {"", "raise: " <> (error |> Exception.message() |> String.slice(0, 200))}
  catch
    kind, value -> {"", "catch: #{inspect(kind)} #{inspect(value)}" |> String.slice(0, 200)}
  end

  defp evaluate(entry, "") do
    # no output: every wanted string is missed, every unwanted one avoided
    %{tp: 0, fn: length(entry.with), fp: 0, tn: length(entry.without)}
  end

  defp evaluate(entry, text) do
    found = Enum.count(entry.with, &String.contains?(text, &1))
    leaked = Enum.count(entry.without, &String.contains?(text, &1))

    %{
      tp: found,
      fn: length(entry.with) - found,
      fp: leaked,
      tn: length(entry.without) - leaked
    }
  end

  defp pool(results) do
    Enum.reduce(results, %{tp: 0, fn: 0, fp: 0, tn: 0}, fn result, totals ->
      Map.merge(totals, Map.take(result, [:tp, :fn, :fp, :tn]), fn _key, a, b -> a + b end)
    end)
  end

  # ## Reporting -----------------------------------------------------------

  defp print_table(results) do
    header = ["Extractor", "Duration (s)", "Precision", "Recall", "Accuracy", "F Score"]

    rows =
      Enum.map(results, fn result ->
        m = metrics(result.totals)

        [
          result.name,
          :erlang.float_to_binary(result.seconds, decimals: 3),
          fmt(m.precision),
          fmt(m.recall),
          fmt(m.accuracy),
          fmt(m.f_score)
        ]
      end)

    widths =
      [header | rows]
      |> Enum.zip_with(& &1)
      |> Enum.map(fn column -> column |> Enum.map(&String.length/1) |> Enum.max() end)

    Mix.shell().info("")
    Mix.shell().info(render_row(header, widths))
    Mix.shell().info(Enum.map_join(widths, "-+-", &String.duplicate("-", &1)))
    Enum.each(rows, &Mix.shell().info(render_row(&1, widths)))
    Mix.shell().info("")
  end

  defp render_row(cells, widths) do
    cells
    |> Enum.zip(widths)
    |> Enum.map_join(" | ", fn {cell, width} -> String.pad_trailing(cell, width) end)
  end

  @doc """
  Precision, recall, accuracy and F-score from pooled counts.

  A denominator of zero yields 0 rather than an error, which only happens on an
  empty corpus.
  """
  @spec metrics(map) :: map
  def metrics(%{tp: tp, fn: fneg, fp: fp, tn: tn}) do
    %{
      precision: ratio(tp, tp + fp),
      recall: ratio(tp, tp + fneg),
      accuracy: ratio(tp + tn, tp + tn + fp + fneg),
      f_score: ratio(2 * tp, 2 * tp + fp + fneg)
    }
  end

  defp ratio(_numerator, 0), do: 0.0
  defp ratio(numerator, denominator), do: numerator / denominator

  defp fmt(value), do: :erlang.float_to_binary(value / 1, decimals: 3)

  defp write_report(path, results) do
    payload =
      Map.new(results, fn result ->
        {result.name,
         %{
           seconds: result.seconds,
           totals: result.totals,
           metrics: metrics(result.totals),
           documents: Enum.sort_by(result.documents, & &1.file)
         }}
      end)

    path |> Path.dirname() |> File.mkdir_p!()
    File.write!(path, Jason.encode!(payload))
    Mix.shell().info("wrote #{path}")
  end
end
