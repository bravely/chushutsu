defmodule Chushutsu.External.JusText do
  @moduledoc """
  A port of the jusText boilerplate classifier, trafilatura's second safety net.

  The document is flattened into paragraphs at block-tag boundaries, each is
  classified from its length, stopword density and link density, then a
  context-sensitive pass promotes or demotes the ambiguous ones based on their
  neighbours. Because it never looks at class or id vocabulary, it reaches
  content buried in anonymous divs that the rule-based extractor walks past.

  Ported from jusText by Jan Pomikálek (BSD-2-Clause); the bundled stoplists are
  that project's data.
  """

  alias Chushutsu.{Text, Tree}
  alias Chushutsu.External.JusText.Stoplists

  @paragraph_tags ~w(body blockquote caption center col colgroup dd div dl dt
                     fieldset form legend optgroup option p pre table td textarea
                     tfoot th thead tr ul li h1 h2 h3 h4 h5 h6)

  # Trafilatura's tuning, which is markedly more permissive than jusText's own
  # defaults: it is a fallback here, not the primary extractor.
  @length_low 50
  @length_high 150
  @stopwords_low 0.1
  @stopwords_high 0.2
  @max_link_density 0.25

  @multiple_whitespace ~r/\s+/u

  defmodule Paragraph do
    @moduledoc false
    defstruct dom_path: "", text_nodes: [], chars_in_links: 0, tags_count: 0, class: nil, cf_class: nil

    @type t :: %__MODULE__{}
  end

  @doc """
  Classifies a document and returns the non-boilerplate paragraph texts.

  `language` is an ISO 639-1 code; when it is unknown the union of every bundled
  stoplist is used, which is the language-agnostic default.
  """
  @spec extract(Tree.t(), Tree.id(), String.t() | nil) :: [String.t()]
  def extract(tree, root, language \\ nil) do
    stoplist = Stoplists.for_language(language)

    tree
    |> make_paragraphs(root)
    |> classify(stoplist)
    |> revise()
    |> Enum.reject(&boilerplate?/1)
    |> Enum.map(&text/1)
  end

  defp boilerplate?(%Paragraph{class: class}), do: class != :good

  # ## Paragraph construction ----------------------------------------------

  # Mirrors jusText's SAX walk: block tags close the current paragraph, inline
  # tags accumulate into it, and `<br><br>` acts as a separator.
  @doc false
  def make_paragraphs(tree, root) do
    state = %{
      path: [],
      paragraphs: [],
      current: %Paragraph{},
      link: false,
      br: false
    }

    state
    |> walk(tree, root)
    |> flush()
    |> Map.fetch!(:paragraphs)
    |> Enum.reverse()
  end

  defp walk(state, tree, id) do
    tag = Tree.tag(tree, id)

    state
    |> start_element(tag)
    |> characters(Tree.text(tree, id))
    |> then(fn state ->
      Enum.reduce(Tree.children(tree, id), state, fn child, state ->
        state
        |> walk(tree, child)
        |> characters(Tree.tail(tree, child))
      end)
    end)
    |> end_element(tag)
  end

  defp start_element(state, tag) do
    state = %{state | path: [tag | state.path]}

    if tag in @paragraph_tags or (tag == "br" and state.br) do
      state
      # a <br><br> separator is not itself part of the paragraph's tag count
      |> then(&if(tag == "br", do: adjust_tags(&1, -1), else: &1))
      |> flush()
    else
      br = tag == "br"

      state
      |> Map.put(:br, br)
      |> then(&if(br, do: append_text(&1, " "), else: &1))
      |> then(&if(not br and tag == "a", do: %{&1 | link: true}, else: &1))
      |> adjust_tags(1)
    end
  end

  defp end_element(state, tag) do
    state = %{state | path: tl(state.path)}
    state = if tag in @paragraph_tags, do: flush(state), else: state
    if tag == "a", do: %{state | link: false}, else: state
  end

  defp characters(state, nil), do: state

  defp characters(state, content) do
    if Text.blank?(content) do
      state
    else
      normalized = normalize_whitespace(content)

      state
      |> append_text(normalized)
      |> then(fn state ->
        if state.link,
          do: %{state | current: %{state.current | chars_in_links: state.current.chars_in_links + Text.len(normalized)}},
          else: state
      end)
      |> Map.put(:br, false)
    end
  end

  defp append_text(state, text) do
    %{state | current: %{state.current | text_nodes: [text | state.current.text_nodes]}}
  end

  defp adjust_tags(state, delta) do
    %{state | current: %{state.current | tags_count: state.current.tags_count + delta}}
  end

  defp flush(state) do
    paragraphs =
      if state.current.text_nodes != [],
        do: [state.current | state.paragraphs],
        else: state.paragraphs

    %{state | paragraphs: paragraphs, current: %Paragraph{dom_path: dom_path(state.path)}}
  end

  defp dom_path(path), do: path |> Enum.reverse() |> Enum.join(".")

  # Collapses whitespace runs, preserving a newline when the run had one.
  defp normalize_whitespace(text) do
    Regex.replace(@multiple_whitespace, text, fn match ->
      if String.contains?(match, "\n") or String.contains?(match, "\r"), do: "\n", else: " "
    end)
  end

  # ## Context-free classification -----------------------------------------

  defp classify(paragraphs, stoplist) do
    Enum.map(paragraphs, fn paragraph ->
      %{paragraph | cf_class: classify_one(paragraph, stoplist)}
    end)
  end

  defp classify_one(paragraph, stoplist) do
    text = text(paragraph)
    length = Text.len(text)

    cond do
      links_density(paragraph, text) > @max_link_density -> :bad
      String.contains?(text, ["©", "&copy"]) -> :bad
      String.contains?(paragraph.dom_path, "select") -> :bad
      length < @length_low -> if paragraph.chars_in_links > 0, do: :bad, else: :short
      true -> classify_by_stopwords(text, length, stoplist)
    end
  end

  defp classify_by_stopwords(text, length, stoplist) do
    density = stopwords_density(text, stoplist)

    cond do
      density >= @stopwords_high and length > @length_high -> :good
      density >= @stopwords_high -> :neargood
      density >= @stopwords_low -> :neargood
      true -> :bad
    end
  end

  defp stopwords_density(text, stoplist) do
    words = String.split(text)

    case length(words) do
      0 -> 0
      count -> Enum.count(words, &MapSet.member?(stoplist, String.downcase(&1))) / count
    end
  end

  defp links_density(paragraph, text) do
    case Text.len(text) do
      0 -> 0
      length -> paragraph.chars_in_links / length
    end
  end

  # ## Context-sensitive revision ------------------------------------------
  #
  # Trafilatura passes `no_headings: true`, so the two heading-promotion passes
  # in upstream jusText never fire and are omitted here.

  defp revise(paragraphs) do
    paragraphs
    |> Enum.map(&%{&1 | class: &1.cf_class})
    |> resolve_shorts()
    |> resolve_neargood()
  end

  # A short paragraph takes the verdict of the block it sits between; when the
  # neighbours disagree, a neargood run on the bad side still rescues it.
  defp resolve_shorts(paragraphs) do
    indexed = List.to_tuple(paragraphs)

    paragraphs
    |> Enum.with_index()
    |> Enum.map(fn
      {%Paragraph{class: :short} = paragraph, index} ->
        %{paragraph | class: resolve_short(indexed, index)}

      {paragraph, _index} ->
        paragraph
    end)
  end

  defp resolve_short(paragraphs, index) do
    previous = neighbour(paragraphs, index, -1, true)
    next = neighbour(paragraphs, index, 1, true)

    cond do
      previous == :good and next == :good -> :good
      previous == :bad and next == :bad -> :bad
      previous == :bad and neighbour(paragraphs, index, -1, false) == :neargood -> :good
      next == :bad and neighbour(paragraphs, index, 1, false) == :neargood -> :good
      true -> :bad
    end
  end

  defp resolve_neargood(paragraphs) do
    indexed = List.to_tuple(paragraphs)

    paragraphs
    |> Enum.with_index()
    |> Enum.map(fn
      {%Paragraph{class: :neargood} = paragraph, index} ->
        previous = neighbour(indexed, index, -1, true)
        next = neighbour(indexed, index, 1, true)
        %{paragraph | class: if(previous == :bad and next == :bad, do: :bad, else: :good)}

      {paragraph, _index} ->
        paragraph
    end)
  end

  # The class at the near end of the run of short/neargood paragraphs.
  defp neighbour(paragraphs, index, step, ignore_neargood) do
    boundary = if step == 1, do: tuple_size(paragraphs), else: -1
    scan(paragraphs, index + step, step, boundary, ignore_neargood)
  end

  defp scan(_paragraphs, index, _step, boundary, _ignore) when index == boundary, do: :bad

  defp scan(paragraphs, index, step, boundary, ignore_neargood) do
    case elem(paragraphs, index).class do
      class when class in [:good, :bad] -> class
      :neargood when not ignore_neargood -> :neargood
      _other -> scan(paragraphs, index + step, step, boundary, ignore_neargood)
    end
  end

  @doc false
  def text(%Paragraph{text_nodes: nodes}) do
    nodes
    |> Enum.reverse()
    |> IO.iodata_to_binary()
    |> String.trim()
    |> normalize_whitespace()
  end
end
