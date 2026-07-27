defmodule Chushutsu do
  @moduledoc """
  Extracts the main text, metadata and comments from a web page.

  An Elixir port of [trafilatura](https://github.com/adbar/trafilatura), covering
  extraction only — fetching pages and discovering links are out of scope, so you
  hand it HTML you already have.

      {:ok, text} = Chushutsu.extract(html)

  ## How it works

  Extraction runs as a cascade, each stage engaging only when the previous one
  came up short: trafilatura's own rules over a located content area, then the
  generic readability and jusText algorithms, then a baseline dump, and finally
  a recall-mode retry when the result still covers little of the page. That keeps
  it precise on conventional markup without giving up on pages that have none.

  ## Options

  See `Chushutsu.Options.new/1`. The common ones:

    * `:output_format` — `:txt` (default), `:markdown`, `:xml`, `:xmltei`,
      `:json`, `:csv` or `:html`
    * `:url` — the page's URL, used to absolutize links and enrich metadata
    * `:favor_precision` / `:favor_recall` — shift the precision/recall balance
    * `:include_comments`, `:include_tables`, `:include_images`,
      `:include_links`, `:include_formatting`
    * `:fast` — skip the generic fallbacks, trading some recall for speed
    * `:with_metadata` — extract metadata and include it in the output
  """

  alias Chushutsu.{Core, Deduplication, Document, Options, Serialize, Tree}

  @doc """
  Extracts a page's main text.

  Returns `{:ok, text}` in the requested format, or `{:error, reason}` when the
  page yields nothing usable — most often `:too_short` for a page with no article
  on it, or `:empty_tree` for input that is not HTML.

  ## Examples

      Chushutsu.extract(html)
      Chushutsu.extract(html, url: "https://example.test/post", output_format: :markdown)
      Chushutsu.extract(html, favor_precision: true, include_comments: false)
  """
  @spec extract(binary | Tree.t(), keyword | Options.t()) :: {:ok, String.t()} | {:error, atom}
  def extract(input, opts \\ []) do
    options = to_options(opts)

    with {:ok, document} <- Core.bare_extraction(input, options) do
      {:ok, Serialize.render(document, options)}
    end
  end

  @doc """
  Like `extract/2` but returns the text directly, or `nil` on failure.

  Convenient when a page yielding nothing is unremarkable rather than an error.
  """
  @spec extract!(binary | Tree.t(), keyword | Options.t()) :: String.t() | nil
  def extract!(input, opts \\ []) do
    case extract(input, opts) do
      {:ok, text} -> text
      {:error, _reason} -> nil
    end
  end

  @doc """
  Extracts text together with metadata.

  Returns `{:ok, %Chushutsu.Document{}}` carrying the rendered `:text` plus
  `:title`, `:author`, `:date`, `:sitename` and the rest.
  """
  @spec extract_with_metadata(binary | Tree.t(), keyword | Options.t()) ::
          {:ok, Document.t()} | {:error, atom}
  def extract_with_metadata(input, opts \\ []) do
    options = opts |> to_options() |> Map.put(:with_metadata, true)

    with {:ok, document} <- Core.bare_extraction(input, options) do
      fingerprint = Deduplication.content_fingerprint("#{document.title} #{document.raw_text}")
      document = %{document | fingerprint: fingerprint}
      {:ok, %{document | text: Serialize.render(document, options)}}
    end
  end

  @doc """
  Extracts without serializing, returning the document with its tree intact.

  Use this to walk the extracted structure rather than a string: `document.tree`
  is a `Chushutsu.Tree` and `document.body` a node id within it.
  """
  @spec bare_extraction(binary | Tree.t(), keyword | Options.t()) ::
          {:ok, Document.t()} | {:error, atom}
  def bare_extraction(input, opts \\ []) do
    Core.bare_extraction(input, to_options(opts))
  end

  @doc """
  Extracts metadata only, skipping content extraction.

  Much cheaper than `extract_with_metadata/2` when the text is not wanted.
  """
  @spec metadata(binary | Tree.t(), keyword | Options.t()) :: {:ok, Document.t()} | {:error, atom}
  def metadata(input, opts \\ []) do
    options = to_options(opts)

    with {:ok, tree, root} <- load(input) do
      {:ok, Chushutsu.Metadata.extract(tree, root, options)}
    end
  end

  @doc """
  Runs only the baseline extractor.

  Skips the content-area rules and goes straight for embedded JSON, `<article>`
  elements and paragraph text — a cheap, layout-agnostic fallback.
  """
  @spec baseline(binary | Tree.t()) :: {:ok, String.t()} | {:error, atom}
  def baseline(input) do
    with {:ok, tree, root} <- load(input) do
      {_tree, _body, text, _length} = Chushutsu.Baseline.extract(tree, root)
      {:ok, text}
    end
  end

  @doc """
  Flattens a whole page to text, with no attempt to find the content.

  Pass `clean: false` to keep the chrome that would otherwise be stripped.
  """
  @spec html_to_text(binary | Tree.t(), keyword) :: {:ok, String.t()} | {:error, atom}
  def html_to_text(input, opts \\ []) do
    with {:ok, tree, root} <- load(input) do
      {:ok, Chushutsu.Baseline.html_to_txt(tree, root, opts)}
    end
  end

  defp load(%Tree{} = tree) do
    case Tree.root(tree) do
      nil -> {:error, :empty_tree}
      root -> {:ok, tree, root}
    end
  end

  defp load(html) when is_binary(html) do
    load(Tree.parse(html))
  end

  defp load(_other), do: {:error, :unsupported_input}

  defp to_options(%Options{} = options), do: options
  defp to_options(opts) when is_list(opts), do: Options.new(opts)
end
