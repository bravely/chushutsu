defmodule Chushutsu.External do
  @moduledoc """
  Deciding when a generic extractor beats trafilatura's own rules.

  The rule-based extractor is precise when a page's markup is conventional and
  blind when it is not. Readability and jusText fail in different places, so the
  cascade runs them and adopts a result only when a specific signal says the own
  extraction fell short.
  """

  require Logger

  alias Chushutsu.{Baseline, HtmlProcessing, Options, Selectors, Settings, Text, Tree}
  alias Chushutsu.External.{JusText, Readability}

  # Tags that should never survive extraction; their presence means the output
  # is unclean enough to be worth a second opinion.
  @sanitized_tags ~w(aside audio button fencedframe fieldset figure footer iframe
                     input label link nav noindex noscript object option select
                     source svg time)

  @doc """
  Compares the own extraction with the generic ones and returns the winner.

  `raw_root` (uncleaned) feeds readability; `cleaned_root` (cleaned but not yet
  tag-converted) feeds jusText.
  """
  @spec compare_extraction(Tree.t(), Tree.id(), Tree.id(), Tree.id(), String.t(), non_neg_integer, Options.t()) ::
          {Tree.t(), Tree.id(), String.t(), non_neg_integer}
  def compare_extraction(tree, cleaned_root, raw_root, body, text, length, options) do
    if options.focus == :recall and length > options.min_extracted_size * 10 do
      # already plenty of text; a second opinion can only dilute it
      {tree, body, text, length}
    else
      do_compare(tree, cleaned_root, raw_root, body, text, length, options)
    end
  end

  defp do_compare(tree, cleaned_root, raw_root, body, text, length, options) do
    {tree, raw_root} =
      if options.focus == :precision,
        do: HtmlProcessing.prune_unwanted_nodes(tree, raw_root, Selectors.overall_discard()),
        else: {tree, raw_root}

    {tree, algo_body} = Readability.summary(tree, raw_root)
    algo_text = if algo_body, do: tree |> Tree.text_content(algo_body) |> Text.trim(), else: ""
    algo_length = Text.len(algo_text)

    use_readability = prefer_readability?(tree, body, algo_body, algo_text, length, algo_length, options)

    {body, text, length} =
      if use_readability, do: {algo_body, algo_text, algo_length}, else: {body, text, length}

    {tree, body, text, length, used_justext} =
      maybe_override_with_justext(tree, cleaned_root, body, text, length, options)

    if use_readability and not used_justext do
      sanitize_tree(tree, body, options)
    else
      {tree, body, text, length}
    end
  end

  @doc false
  def prefer_readability?(tree, body, algo_body, algo_text, length, algo_length, options) do
    cond do
      # empty, or the same size as the own extraction (assumed same content)
      algo_body == nil or algo_length == 0 or algo_length == length -> false
      # own extraction much longer
      length > 2 * algo_length -> false
      length == 0 -> true
      # readability much longer, unless it grabbed raw JSON
      algo_length > 2 * length and not String.starts_with?(algo_text, "{") -> true
      structurally_deficient?(tree, body, algo_length, options) -> true
      options.focus == :recall and algo_length > 1.5 * length and not String.starts_with?(algo_text, "{") -> true
      options.focus == :recall -> recovers_headed_article?(tree, body, algo_body, algo_length, length)
      true -> false
    end
  end

  # No paragraph text at all, or so table-dominated that the "article" is a grid.
  defp structurally_deficient?(tree, body, algo_length, options) do
    algo_length > options.min_extracted_size * 2 and
      (no_paragraph_text?(tree, body) or
         length(Tree.find_all(tree, body, "table")) > length(Tree.find_all(tree, body, "p")))
  end

  defp no_paragraph_text?(tree, body) do
    tree
    |> Tree.find_all(body, "p")
    |> Enum.all?(&(Tree.text_content(tree, &1) == ""))
  end

  # Readability found a headed article where the own extraction found no heading.
  defp recovers_headed_article?(tree, body, algo_body, algo_length, length) do
    Tree.find(tree, body, "head") == nil and
      Tree.find_all(tree, algo_body, ~w(h2 h3 h4)) != [] and
      algo_length > length
  end

  defp maybe_override_with_justext(tree, cleaned_root, body, text, length, options) do
    if unclean?(tree, body) or length < options.min_extracted_size do
      {tree, jt_body, jt_text, jt_length} = justext_rescue(tree, cleaned_root, options)

      # a much shorter justext result must not displace the main text
      if jt_text != "" and length <= Settings.justext_override_ratio() * jt_length,
        do: {tree, jt_body, jt_text, jt_length, true},
        else: {tree, body, text, length, false}
    else
      {tree, body, text, length, false}
    end
  end

  defp unclean?(tree, body), do: Tree.find(tree, body, @sanitized_tags) != nil

  @doc """
  Runs jusText over a cleaned tree, returning a fresh body of paragraphs.
  """
  @spec justext_rescue(Tree.t(), Tree.id(), Options.t()) ::
          {Tree.t(), Tree.id(), String.t(), non_neg_integer}
  def justext_rescue(tree, root, options) do
    {tree, working} = Tree.deep_copy(tree, root)
    tree = Baseline.basic_cleaning(tree, working)

    texts = JusText.extract(tree, working, options.lang)
    {tree, body} = Tree.create(tree, "body")

    tree =
      Enum.reduce(texts, tree, fn text, tree ->
        {tree, paragraph} = Tree.create_child(tree, body, "p")
        Tree.put_text(tree, paragraph, text)
      end)

    result = tree |> Tree.itertext(body) |> Enum.join(" ") |> Text.trim()
    {tree, body, result, Text.len(result)}
  rescue
    error ->
      Logger.warning("justext failed: #{Exception.message(error)}")
      {tree, nil, "", 0}
  end

  @doc """
  Post-processes a readability result into the extractor's own vocabulary.

  Readability returns raw HTML, so it has to go through the same cleaning and
  conversion the main path applies before it can be serialized alongside it.
  """
  @spec sanitize_tree(Tree.t(), Tree.id(), Options.t()) ::
          {Tree.t(), Tree.id(), String.t(), non_neg_integer}
  def sanitize_tree(tree, root, options) do
    {tree, root} = HtmlProcessing.tree_cleaning(tree, root, options)

    tree =
      tree
      |> then(&if(options.links, do: &1, else: Tree.strip_tags(&1, root, ["a"])))
      |> Tree.strip_tags(root, ["span"])
      |> HtmlProcessing.convert_tags(root, options, options.url)
      |> mark_header_rows(root)
      |> rename_table_elements(root)

    # anything outside the TEI vocabulary is unwrapped, keeping its text
    invalid =
      tree
      |> Tree.iter(root)
      |> Enum.map(&Tree.tag(tree, &1))
      |> Enum.uniq()
      |> Enum.reject(&(&1 in Settings.tei_valid_tags()))

    tree = Tree.strip_tags(tree, root, invalid)
    text = tree |> Tree.itertext(root) |> Enum.join(" ") |> Text.trim()
    {tree, root, text, Text.len(text)}
  end

  # Mirrors handle_table: the first <th>-bearing row per parent becomes the head.
  defp mark_header_rows(tree, root) do
    tree
    |> Tree.iter(root, ["tr"])
    |> Enum.reduce({tree, MapSet.new()}, fn row, {tree, seen} ->
      parent = Tree.parent(tree, row)
      headers = tree |> Tree.children(row) |> Enum.filter(&(Tree.tag(tree, &1) == "th"))

      if headers != [] and not MapSet.member?(seen, parent) do
        tree = Enum.reduce(headers, tree, &Tree.put_attr(&2, &1, "role", "head"))
        {tree, MapSet.put(seen, parent)}
      else
        {tree, seen}
      end
    end)
    |> elem(0)
  end

  defp rename_table_elements(tree, root) do
    tree
    |> Tree.iter(root, ~w(td th tr))
    |> Enum.reduce(tree, fn id, tree ->
      case Tree.tag(tree, id) do
        "tr" -> Tree.put_tag(tree, id, "row")
        _cell -> Tree.put_tag(tree, id, "cell")
      end
    end)
  end
end
