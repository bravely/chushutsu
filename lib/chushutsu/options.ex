defmodule Chushutsu.Options do
  @moduledoc """
  Extraction configuration.

  Build one with `new/1` from a keyword list; the public API does that for you,
  so you only need this module when reusing a configuration across many
  documents.
  """

  alias Chushutsu.Settings

  @formats ~w(txt markdown xml xmltei json csv html python)a
  @focuses ~w(balanced precision recall)a

  defstruct format: :txt,
            fast: false,
            focus: :balanced,
            comments: true,
            formatting: false,
            links: false,
            images: false,
            tables: true,
            dedup: false,
            lang: nil,
            url: nil,
            source: nil,
            with_metadata: false,
            only_with_metadata: false,
            tei_validation: false,
            author_blacklist: MapSet.new(),
            url_blacklist: MapSet.new(),
            min_extracted_size: 250,
            min_output_size: 1,
            min_extracted_comm_size: 1,
            min_output_comm_size: 1,
            min_duplcheck_size: 100,
            max_repetitions: 2,
            max_tree_size: nil

  @type focus :: :balanced | :precision | :recall
  @type t :: %__MODULE__{}

  @doc """
  Builds an options struct.

  ## Options

    * `:output_format` — `:txt` (default), `:markdown`, `:xml`, `:xmltei`,
      `:json`, `:csv`, `:html` or `:python`
    * `:url` — source URL, used to absolutize links and for metadata
    * `:fast` — skip the readability/justext fallbacks
    * `:favor_precision` / `:favor_recall` — shift the precision/recall balance
    * `:include_comments` — extract comments too (default `true`)
    * `:include_tables` — keep table content (default `true`)
    * `:include_images` / `:include_links` / `:include_formatting`
    * `:deduplicate` — drop segments already seen in this process
    * `:target_language` — discard documents not in this language (ISO 639-1)
    * `:with_metadata` / `:only_with_metadata`
    * `:author_blacklist` / `:url_blacklist`

  `:favor_precision` and `:favor_recall` are mutually exclusive; recall wins if
  both are given, matching upstream.
  """
  @spec new(keyword) :: t
  def new(opts \\ []) do
    format = normalize_format(Keyword.get(opts, :output_format, :txt))
    focus = normalize_focus(opts)

    %__MODULE__{
      format: format,
      fast: Keyword.get(opts, :fast, false),
      focus: focus,
      comments: Keyword.get(opts, :include_comments, true),
      # markdown implies formatting, but an explicit false is honoured
      formatting:
        Keyword.get(opts, :include_formatting) ||
          (is_nil(Keyword.get(opts, :include_formatting)) and format == :markdown),
      links: Keyword.get(opts, :include_links, false),
      images: Keyword.get(opts, :include_images, false),
      tables: Keyword.get(opts, :include_tables, true),
      dedup: Keyword.get(opts, :deduplicate, false),
      lang: Keyword.get(opts, :target_language),
      url: Keyword.get(opts, :url),
      source: Keyword.get(opts, :url) || Keyword.get(opts, :source),
      only_with_metadata: Keyword.get(opts, :only_with_metadata, false),
      tei_validation: Keyword.get(opts, :tei_validation, false),
      author_blacklist: to_set(Keyword.get(opts, :author_blacklist)),
      url_blacklist: to_set(Keyword.get(opts, :url_blacklist)),
      with_metadata: with_metadata?(opts, format),
      min_extracted_size: Keyword.get(opts, :min_extracted_size, Settings.min_extracted_size()),
      min_output_size: Keyword.get(opts, :min_output_size, Settings.min_output_size()),
      min_extracted_comm_size: Settings.min_extracted_comm_size(),
      min_output_comm_size: Settings.min_output_comm_size(),
      min_duplcheck_size: Settings.min_duplcheck_size(),
      max_repetitions: Settings.max_repetitions(),
      max_tree_size: Keyword.get(opts, :max_tree_size)
    }
  end

  defp normalize_format(format) when format in @formats, do: format

  defp normalize_format(format) when is_binary(format) do
    normalize_format(String.to_existing_atom(format))
  rescue
    ArgumentError -> raise ArgumentError, bad_format(format)
  end

  defp normalize_format(format), do: raise(ArgumentError, bad_format(format))

  defp bad_format(format) do
    "unsupported output format #{inspect(format)}, expected one of: #{Enum.map_join(@formats, ", ", &inspect/1)}"
  end

  defp normalize_focus(opts) do
    cond do
      Keyword.get(opts, :favor_recall, false) -> :recall
      Keyword.get(opts, :favor_precision, false) -> :precision
      true -> normalize_explicit_focus(Keyword.get(opts, :focus, :balanced))
    end
  end

  defp normalize_explicit_focus(focus) when focus in @focuses, do: focus
  defp normalize_explicit_focus(other), do: raise(ArgumentError, "unknown focus #{inspect(other)}")

  # Metadata gets extracted implicitly whenever something downstream needs it.
  defp with_metadata?(opts, format) do
    Keyword.get(opts, :with_metadata, false) or
      Keyword.get(opts, :only_with_metadata, false) or
      to_set(Keyword.get(opts, :url_blacklist)) != MapSet.new() or
      to_set(Keyword.get(opts, :author_blacklist)) != MapSet.new() or
      format == :xmltei
  end

  defp to_set(nil), do: MapSet.new()
  defp to_set(%MapSet{} = set), do: set
  defp to_set(list) when is_list(list), do: MapSet.new(list)

  @doc "Returns the options with a different focus, leaving the caller's copy untouched."
  @spec with_focus(t, focus) :: t
  def with_focus(%__MODULE__{} = options, focus), do: %{options | focus: focus}

  @doc "Whether the output format is one of the plain-text flavours."
  @spec text_format?(t) :: boolean
  def text_format?(%__MODULE__{format: format}), do: format in [:txt, :markdown]
end
