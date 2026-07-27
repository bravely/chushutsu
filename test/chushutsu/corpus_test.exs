defmodule Chushutsu.CorpusTest do
  @moduledoc """
  Accuracy regression guard over the annotated comparison corpus.

  The corpus is ~150 MB of third-party HTML and is not vendored, so these tests
  are skipped unless `CHUSHUTSU_CORPUS` points at a go-trafilatura `test-files`
  directory. `mix chushutsu.eval` runs the same measurement with a full report.

  The floors are set just below the measured scores. They exist to catch a
  regression, not to pin the exact numbers — a change that improves them should
  raise the floor rather than be treated as a failure.
  """

  use ExUnit.Case, async: true

  @sample 150

  # Measured over the full 960-document corpus:
  #   standard  P 0.920  R 0.909  F 0.915
  #   fallback  P 0.921  R 0.921  F 0.921
  # A sample runs here, so the floors carry a margin for sampling variation.
  @min_f_score 0.87
  @min_precision 0.87

  setup_all do
    case corpus_dir() do
      nil -> {:ok, skip: "set CHUSHUTSU_CORPUS to run corpus tests"}
      dir -> {:ok, entries: load_entries(dir)}
    end
  end

  # Read at runtime rather than baked into a module attribute, so setting the
  # variable takes effect without a recompile.
  defp corpus_dir do
    case System.get_env("CHUSHUTSU_CORPUS") do
      dir when is_binary(dir) -> if File.dir?(dir), do: dir, else: nil
      nil -> nil
    end
  end

  describe "accuracy" do
    @tag :corpus
    test "meets the F-score floor in fast mode", context do
      run_or_skip(context, fast: true)
    end

    @tag :corpus
    test "meets the F-score floor with the generic fallbacks", context do
      run_or_skip(context, [])
    end

    @tag :corpus
    test "no document crashes the extractor", context do
      if context[:skip] do
        assert true
      else
        failures =
          context.entries
          |> Enum.map(&extract_safely(&1, []))
          |> Enum.filter(&match?({:error, _, _}, &1))

        assert failures == [], "extraction raised on: #{inspect(Enum.take(failures, 5))}"
      end
    end
  end

  defp run_or_skip(context, opts) do
    if context[:skip] do
      assert true
    else
      totals =
        context.entries
        |> Enum.map(&score(&1, opts))
        |> Enum.reduce(%{tp: 0, fn: 0, fp: 0, tn: 0}, fn row, acc ->
          Map.merge(acc, row, fn _key, a, b -> a + b end)
        end)

      metrics = Mix.Tasks.Chushutsu.Eval.metrics(totals)

      assert metrics.f_score >= @min_f_score,
             "F-score #{Float.round(metrics.f_score, 3)} fell below #{@min_f_score} (#{inspect(totals)})"

      assert metrics.precision >= @min_precision,
             "precision #{Float.round(metrics.precision, 3)} fell below #{@min_precision}"
    end
  end

  # A fixed stride rather than the first N, so the sample spans the whole corpus
  # instead of whatever sorts first.
  defp load_entries(corpus) do
    all =
      "bench/comparison.json"
      |> File.read!()
      |> Jason.decode!()
      |> Enum.sort_by(& &1["file"])
      |> Enum.flat_map(fn entry ->
        case find_file(corpus, entry["file"]) do
          nil -> []
          path -> [Map.put(entry, "path", path)]
        end
      end)

    stride = max(div(length(all), @sample), 1)

    all
    |> Enum.take_every(stride)
    |> Enum.take(@sample)
  end

  defp find_file(corpus, name) do
    Enum.find_value(["comparison", "mock"], fn dir ->
      path = Path.join([corpus, dir, name])
      if File.exists?(path), do: path
    end)
  end

  defp score(entry, opts) do
    text =
      case extract_safely(entry, opts) do
        {:ok, text} -> text
        {:error, _file, _reason} -> ""
      end

    found = Enum.count(entry["with"], &String.contains?(text, &1))
    leaked = Enum.count(entry["without"], &String.contains?(text, &1))

    %{
      tp: found,
      fn: length(entry["with"]) - found,
      fp: leaked,
      tn: length(entry["without"]) - leaked
    }
  end

  defp extract_safely(entry, opts) do
    options = Keyword.merge([include_comments: false, url: entry["url"]], opts)

    case Chushutsu.extract(File.read!(entry["path"]), options) do
      {:ok, text} -> {:ok, text}
      # a page with no article is a legitimate outcome, not a crash
      {:error, _reason} -> {:ok, ""}
    end
  rescue
    error -> {:error, entry["file"], Exception.message(error)}
  catch
    kind, value -> {:error, entry["file"], "#{inspect(kind)} #{inspect(value)}"}
  end
end
