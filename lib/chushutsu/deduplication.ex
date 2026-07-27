defmodule Chushutsu.Deduplication do
  @moduledoc """
  Repetition detection across documents, enabled with `deduplicate: true`.

  Segments seen more than `max_repetitions` times are treated as boilerplate.
  This is inherently cross-document state — a segment is only suspicious because
  it recurred *elsewhere* — so it lives in a named ETS table with LRU eviction
  rather than being threaded through the extraction.

  Call `reset/0` between unrelated batches, and note that with `deduplicate:
  false` (the default) none of this runs.
  """

  use GenServer

  alias Chushutsu.{Settings, Text, Tree}

  @table __MODULE__

  # ## Public API ----------------------------------------------------------

  @doc "Starts the shared segment cache. Started on demand if you skip this."
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Empties the cache."
  @spec reset() :: :ok
  def reset do
    ensure_started()
    :ets.delete_all_objects(@table)
    :ok
  end

  @doc """
  Whether an element's text has already been seen too often.

  Short segments are never considered: a repeated sentence fragment is common in
  legitimate prose, and only substantial repeats indicate boilerplate.
  """
  @spec duplicate?(Tree.t(), Tree.id(), Chushutsu.Options.t()) :: boolean
  def duplicate?(tree, id, options) do
    tree
    |> Tree.itertext(id)
    |> Enum.join(" ")
    |> Text.normalize_space()
    |> duplicate_text?(options)
  end

  @doc "The `duplicate?/3` check against a bare string."
  @spec duplicate_text?(String.t(), Chushutsu.Options.t()) :: boolean
  def duplicate_text?(text, options) do
    ensure_started()

    if Text.len(text) > options.min_duplcheck_size do
      case seen_count(text) do
        count when count > options.max_repetitions ->
          record(text, count + 1)
          true

        count ->
          record(text, count + 1)
          false
      end
    else
      record(text, seen_count(text) + 1)
      false
    end
  end

  @doc """
  A stable fingerprint of a document's content.

  Used to identify the same article served at several URLs.
  """
  @spec content_fingerprint(String.t()) :: String.t()
  def content_fingerprint(text) do
    text
    |> sample_tokens()
    |> Enum.join(" ")
    |> String.trim()
    |> then(&:crypto.hash(:blake2b, &1))
    |> binary_part(0, 24)
    |> Base.encode16(case: :lower)
  end

  @doc """
  Splits text into alphanumeric tokens for fingerprinting.

  Progressively drops the shortest tokens until either the sample is big enough
  or nothing is left, so that short documents still produce a usable signature.
  """
  @spec sample_tokens(String.t(), pos_integer) :: [String.t()]
  def sample_tokens(text, target \\ 64) do
    tokens =
      text
      |> String.split()
      |> Enum.map(&String.trim(&1, "."))
      |> Enum.map(&strip_punctuation/1)
      |> Enum.filter(&alphanumeric?/1)

    case sample_by_length(tokens, target) do
      [] -> fallback_tokens(text, target)
      sample -> sample
    end
  end

  # Scripts without Latin punctuation (e.g. Mandarin's 。) tokenize to nothing
  # above; splitting on punctuation directly recovers them.
  defp fallback_tokens(text, target) do
    text
    |> String.replace(~r/\p{P}/u, " ")
    |> String.split()
    |> Enum.filter(&alphanumeric?/1)
    |> sample_by_length(target)
  end

  defp sample_by_length(tokens, target) do
    Enum.reduce_while(4..0//-1, [], fn min_length, _acc ->
      sample = Enum.filter(tokens, &(Text.len(&1) > min_length))
      if length(sample) >= target / 2, do: {:halt, sample}, else: {:cont, sample}
    end)
  end

  defp strip_punctuation(token) do
    token
    |> String.replace(~r/^\p{P}+/u, "")
    |> String.replace(~r/\p{P}+$/u, "")
  end

  defp alphanumeric?(""), do: false
  defp alphanumeric?(token), do: Regex.match?(~r/^[\p{L}\p{N}]+$/u, token)

  # ## Cache ---------------------------------------------------------------

  defp seen_count(text) do
    case :ets.lookup(@table, key(text)) do
      [{_key, count, _stamp}] -> count
      [] -> -1
    end
  end

  defp record(text, count) do
    :ets.insert(@table, {key(text), max(count, 0), :erlang.unique_integer([:monotonic])})
    maybe_evict()
  end

  # Hashing keeps the table small regardless of segment length.
  defp key(text), do: :erlang.phash2({byte_size(text), :crypto.hash(:sha256, text)})

  defp maybe_evict do
    if :ets.info(@table, :size) > Settings.lru_size() do
      GenServer.cast(__MODULE__, :evict)
    end

    :ok
  end

  defp ensure_started do
    case Process.whereis(__MODULE__) do
      nil ->
        case start_link() do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
        end

      _pid ->
        :ok
    end
  end

  # ## GenServer -----------------------------------------------------------

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true, write_concurrency: true])
    {:ok, %{}}
  end

  @impl true
  def handle_cast(:evict, state) do
    # drop the oldest quarter so eviction is amortized rather than per-insert
    target = div(Settings.lru_size(), 4)

    @table
    |> :ets.tab2list()
    |> Enum.sort_by(&elem(&1, 2))
    |> Enum.take(target)
    |> Enum.each(fn {key, _count, _stamp} -> :ets.delete(@table, key) end)

    {:noreply, state}
  end
end
