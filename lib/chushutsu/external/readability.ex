defmodule Chushutsu.External.Readability do
  @moduledoc """
  A minimal fork of readability-lxml, used as trafilatura's first safety net.

  Scores block containers by the amount of comma-bearing paragraph text they
  hold, picks the best one, then prunes what looks like chrome. Where the
  rule-based extractor keys off class and id vocabulary, this keys off text
  shape, so the two fail in different places.

  Derived from arc90's Readability by way of the Ruby and Python ports.
  Apache-2.0, like the trafilatura fork it comes from.
  """

  require Logger

  alias Chushutsu.{Text, Tree}

  @div_scores ~w(div article)
  @block_scores ~w(pre td blockquote)
  @bad_elem_scores ~w(address ol ul dl dd dt li form aside)
  @structure_scores ~w(h1 h2 h3 h4 h5 h6 th header footer nav)
  @text_clean_elems ~w(p img li a embed input)
  @frame_tags ~w(body html)
  @list_tags ~w(ol ul)
  @headings ~w(h1 h2 h3 h4 h5 h6)

  @unlikely_candidates ~r/combx|comment|community|disqus|extra|foot|header|menu|remark|rss|shoutbox|sidebar|sponsor|ad-break|agegate|pagination|pager|popup|tweet|twitter/i
  @maybe_candidate ~r/and|article|body|column|main|shadow/i
  @positive ~r/article|body|content|entry|hentry|main|page|pagination|post|text|blog|story/i
  @negative ~r/button|combx|comment|com-|contact|figure|foot|footer|footnote|form|input|masthead|media|meta|outbrain|promo|related|scroll|shoutbox|sidebar|sponsor|shopping|tags|tool|widget/i
  # Upstream tests `<(?:a|blockquote|dl|div|img|ol|p|pre|table|ul)` against the
  # serialized children. That pattern has no word boundary, so `<a` also matches
  # `<article`/`<aside` and `<p` matches `<pre`/`<picture` — a quirk the div
  # promotion is calibrated around, so it is reproduced as a prefix test.
  # (`pre` is omitted below because `p` already subsumes it.)
  #
  # Checking tags directly rather than serializing matters: serializing every
  # div's subtree to HTML made escaping alone ~7% of total runtime, and the
  # escaping is pure waste here since only tag names are ever examined.
  @div_to_p_prefixes ~w(a blockquote div dl img ol p table ul)
  @video ~r"https?://(?:www\.)?(?:youtube|vimeo)\.com"i
  @dot_space ~r/\.( |$)/

  @doc """
  Extracts the most article-like part of a document.

  Returns `{tree, id}`, or `{tree, nil}` when nothing could be salvaged. The
  input is copied, so the caller's tree is untouched.
  """
  @spec summary(Tree.t(), Tree.id(), keyword) :: {Tree.t(), Tree.id() | nil}
  def summary(tree, root, opts \\ []) do
    min_text_length = Keyword.get(opts, :min_text_length, 25)
    retry_length = Keyword.get(opts, :retry_length, 250)

    {tree, doc} = Tree.deep_copy(tree, root)
    tree = drop_all(tree, doc, ~w(script style fencedframe))

    attempt(tree, doc, min_text_length, retry_length, true)
  rescue
    error ->
      Logger.warning("readability failed: #{Exception.message(error)}")
      {tree, nil}
  end

  # `ruthless` strips unlikely candidates up front. When that leaves too little,
  # the whole pass is repeated in a more forgiving mode.
  defp attempt(tree, doc, min_text_length, retry_length, ruthless) do
    {tree, working} = Tree.deep_copy(tree, doc)
    tree = if ruthless, do: remove_unlikely_candidates(tree, working), else: tree
    tree = transform_misused_divs(tree, working)

    candidates = score_paragraphs(tree, working, min_text_length)

    {tree, article} =
      case select_best_candidate(candidates) do
        nil when ruthless -> {tree, nil}
        nil -> {tree, Tree.find(tree, working, "body") || working}
        best -> get_article(tree, candidates, best)
      end

    cond do
      article == nil ->
        attempt(tree, doc, min_text_length, retry_length, false)

      true ->
        {tree, cleaned} = sanitize(tree, article, candidates, min_text_length)
        html_length = tree |> Tree.to_html(cleaned) |> Text.len()

        if ruthless and html_length < retry_length,
          do: attempt(tree, doc, min_text_length, retry_length, false),
          else: {tree, cleaned}
    end
  end

  # ## Scoring -------------------------------------------------------------

  defp score_paragraphs(tree, root, min_text_length) do
    tree
    |> Tree.iter(root, ~w(p pre td))
    |> Enum.reduce(%{}, fn elem, candidates ->
      parent = Tree.parent(tree, elem)
      grandparent = parent && Tree.parent(tree, parent)
      text = tree |> Tree.text_content(elem) |> Text.normalize_space()

      if parent == nil or Text.len(text) < min_text_length do
        candidates
      else
        candidates
        |> ensure_candidate(tree, parent)
        |> ensure_candidate(tree, grandparent)
        |> add_score(parent, paragraph_score(text))
        |> add_score(grandparent, paragraph_score(text) / 2)
      end
    end)
    |> scale_by_link_density(tree)
  end

  # Commas are a decent proxy for prose; length contributes but saturates.
  defp paragraph_score(text) do
    1 + length(String.split(text, ",")) + min(Text.len(text) / 100, 3)
  end

  defp ensure_candidate(candidates, _tree, nil), do: candidates

  defp ensure_candidate(candidates, tree, id) do
    if Map.has_key?(candidates, id),
      do: candidates,
      else: Map.put(candidates, id, %{score: score_node(tree, id), order: map_size(candidates)})
  end

  defp add_score(candidates, nil, _score), do: candidates

  defp add_score(candidates, id, score) do
    Map.update!(candidates, id, &%{&1 | score: &1.score + score})
  end

  # Good content has a low link density, so this barely touches it.
  defp scale_by_link_density(candidates, tree) do
    Map.new(candidates, fn {id, candidate} ->
      {id, %{candidate | score: candidate.score * (1 - link_density(tree, id))}}
    end)
  end

  defp score_node(tree, id) do
    tag = Tree.tag(tree, id)

    class_weight(tree, id) +
      cond do
        tag in @div_scores -> 5
        tag in @block_scores -> 3
        tag in @bad_elem_scores -> -3
        tag in @structure_scores -> -5
        true -> 0
      end
  end

  defp class_weight(tree, id) do
    ["class", "id"]
    |> Enum.map(&Tree.attr(tree, id, &1))
    |> Enum.reject(&is_nil/1)
    |> Enum.reduce(0, fn value, weight ->
      weight
      |> then(&if(Regex.match?(@negative, value), do: &1 - 25, else: &1))
      |> then(&if(Regex.match?(@positive, value), do: &1 + 25, else: &1))
    end)
  end

  defp link_density(tree, id) do
    total = max(text_length(tree, id), 1)
    links = tree |> Tree.find_all(id, "a") |> Enum.map(&text_length(tree, &1)) |> Enum.sum()
    links / total
  end

  defp text_length(tree, id), do: tree |> Tree.text_content(id) |> Text.normalize_space() |> Text.len()

  defp select_best_candidate(candidates) when map_size(candidates) == 0, do: nil

  defp select_best_candidate(candidates) do
    candidates
    |> Enum.sort_by(fn {_id, c} -> {-c.score, c.order} end)
    |> List.first()
    |> elem(0)
  end

  # ## Article assembly ----------------------------------------------------

  # Siblings of the winner often hold content split apart by removed ads, so
  # they are pulled in when they score well enough or read like prose.
  defp get_article(tree, candidates, best) do
    threshold = max(10, candidates[best].score * 0.2)
    parent = Tree.parent(tree, best)
    siblings = if parent, do: Tree.children(tree, parent), else: [best]

    {tree, output} = Tree.create(tree, "div")

    tree =
      Enum.reduce(siblings, tree, fn sibling, tree ->
        if keep_sibling?(tree, sibling, best, candidates, threshold),
          do: Tree.append(tree, output, sibling),
          else: tree
      end)

    {tree, output}
  end

  defp keep_sibling?(tree, sibling, best, candidates, threshold) do
    cond do
      sibling == best -> true
      match?(%{score: _}, candidates[sibling]) -> candidates[sibling].score >= threshold
      Tree.tag(tree, sibling) == "p" -> prose_paragraph?(tree, sibling)
      true -> false
    end
  end

  defp prose_paragraph?(tree, sibling) do
    density = link_density(tree, sibling)
    content = Tree.text(tree, sibling) || ""
    length = Text.len(content)

    (length > 80 and density < 0.25) or
      (length <= 80 and density == 0 and Regex.match?(@dot_space, content))
  end

  # ## Pruning -------------------------------------------------------------

  defp remove_unlikely_candidates(tree, root) do
    tree
    |> Tree.iterdescendants(root)
    |> Enum.filter(fn id ->
      attrs = [Tree.attr(tree, id, "class"), Tree.attr(tree, id, "id")]
      joined = attrs |> Enum.reject(&is_nil/1) |> Enum.join(" ")

      Text.len(joined) >= 2 and Tree.tag(tree, id) not in @frame_tags and
        Regex.match?(@unlikely_candidates, joined) and not Regex.match?(@maybe_candidate, joined)
    end)
    |> Enum.reduce(tree, fn id, tree ->
      if Tree.exists?(tree, id), do: Tree.delete_element(tree, id), else: tree
    end)
  end

  # A div holding no block children is really a paragraph; loose text and tails
  # inside a div get wrapped so the scorer can see them.
  defp transform_misused_divs(tree, root) do
    tree =
      tree
      |> Tree.iter(root, ["div"])
      |> Enum.reduce(tree, fn id, tree ->
        if holds_block_markup?(tree, Tree.children(tree, id)),
          do: tree,
          else: Tree.put_tag(tree, id, "p")
      end)

    tree
    |> Tree.iter(root, ["div"])
    |> Enum.reduce(tree, &wrap_loose_text(&2, &1))
  end

  @doc """
  Whether any of these subtrees carries block-level markup.

  Exposed for testing: the prefix semantics below are a deliberate quirk and
  easy to mistake for a bug.
  """
  @spec holds_block_markup?(Tree.t(), [Tree.id()]) :: boolean
  # Short-circuits on the first block-ish tag rather than walking every subtree.
  def holds_block_markup?(_tree, []), do: false

  def holds_block_markup?(tree, [id | rest]) do
    block_tag?(Tree.tag(tree, id)) or
      holds_block_markup?(tree, Tree.children(tree, id)) or
      holds_block_markup?(tree, rest)
  end

  defp block_tag?(nil), do: false
  defp block_tag?(tag), do: Enum.any?(@div_to_p_prefixes, &String.starts_with?(tag, &1))

  defp wrap_loose_text(tree, div) do
    tree =
      if Text.normalize_space(Tree.text(tree, div)) != "" do
        {tree, paragraph} = Tree.create(tree, "p")

        tree
        |> Tree.put_text(paragraph, Tree.text(tree, div))
        |> Tree.put_text(div, nil)
        |> Tree.insert(div, 0, paragraph)
      else
        tree
      end

    tree
    |> Tree.children(div)
    |> Enum.with_index()
    |> Enum.reverse()
    |> Enum.reduce(tree, fn {child, position}, tree ->
      tree
      |> wrap_tail(div, child, position)
      |> drop_line_break(child)
    end)
  end

  defp wrap_tail(tree, div, child, position) do
    if Text.normalize_space(Tree.tail(tree, child)) != "" do
      {tree, paragraph} = Tree.create(tree, "p")

      tree
      |> Tree.put_text(paragraph, Tree.tail(tree, child))
      |> Tree.put_tail(child, nil)
      |> Tree.insert(div, position + 1, paragraph)
    else
      tree
    end
  end

  defp drop_line_break(tree, child) do
    if Tree.exists?(tree, child) and Tree.tag(tree, child) == "br",
      do: Tree.delete_element(tree, child),
      else: tree
  end

  # ## Sanitizing ----------------------------------------------------------

  defp sanitize(tree, node, candidates, min_text_length) do
    tree =
      tree
      |> drop_weak_headings(node)
      |> drop_all(node, ~w(form textarea))
      |> handle_iframes(node)
      |> conditionally_clean(node, candidates, min_text_length)

    {tree, node}
  end

  defp drop_weak_headings(tree, node) do
    tree
    |> Tree.iter(node, @headings)
    |> Enum.filter(&(class_weight(tree, &1) < 0 or link_density(tree, &1) > 0.33))
    |> Enum.reduce(tree, &delete_if_present(&2, &1))
  end

  defp drop_all(tree, node, tags) do
    tree
    |> Tree.iter(node, tags)
    |> Enum.reduce(tree, &delete_if_present(&2, &1))
  end

  defp handle_iframes(tree, node) do
    tree
    |> Tree.iter(node, ["iframe"])
    |> Enum.reduce(tree, fn id, tree ->
      src = Tree.attr(tree, id, "src")

      if src && Regex.match?(@video, src),
        # keep the frame with placeholder text so the video is not silently lost
        do: Tree.put_text(tree, id, "VIDEO"),
        else: delete_if_present(tree, id)
    end)
  end

  defp conditionally_clean(tree, node, candidates, min_text_length) do
    targets = Tree.iter(tree, node, ~w(table ul div aside header footer section))

    {tree, _allowed} =
      targets
      |> Enum.reverse()
      |> Enum.reduce({tree, MapSet.new()}, fn id, {tree, allowed} ->
        if not Tree.exists?(tree, id) or MapSet.member?(allowed, id) do
          {tree, allowed}
        else
          clean_one(tree, id, candidates, allowed, min_text_length)
        end
      end)

    tree
  end

  defp clean_one(tree, id, candidates, allowed, min_text_length) do
    weight = class_weight(tree, id)
    score = candidate_score(candidates, id)

    cond do
      weight + score < 0 ->
        {delete_if_present(tree, id), allowed}

      # a comma-rich block is prose, whatever its structure looks like
      tree |> Tree.text_content(id) |> count_commas() >= 10 ->
        {tree, allowed}

      true ->
        evaluate_block(tree, id, weight, allowed, min_text_length)
    end
  end

  defp evaluate_block(tree, id, weight, allowed, min_text_length) do
    counts = element_counts(tree, id)
    content_length = text_length(tree, id)
    density = link_density(tree, id)

    cond do
      counts.p > 0 and counts.img > 1 + counts.p * 1.3 -> {delete_if_present(tree, id), allowed}
      counts.li > counts.p and Tree.tag(tree, id) not in @list_tags -> {delete_if_present(tree, id), allowed}
      counts.input > counts.p / 3 -> {delete_if_present(tree, id), allowed}
      content_length < min_text_length and counts.img == 0 -> {delete_if_present(tree, id), allowed}
      content_length < min_text_length and counts.img > 2 -> {delete_if_present(tree, id), allowed}
      weight < 25 and density > 0.2 -> {delete_if_present(tree, id), allowed}
      weight >= 25 and density > 0.5 -> {delete_if_present(tree, id), allowed}
      (counts.embed == 1 and content_length < 75) or counts.embed > 1 -> {delete_if_present(tree, id), allowed}
      content_length == 0 -> handle_empty_block(tree, id, allowed)
      true -> {tree, allowed}
    end
  end

  # An empty container between two substantial siblings is a layout artifact
  # worth keeping, since removing it would break the surrounding structure.
  defp handle_empty_block(tree, id, allowed) do
    siblings = neighbour_lengths(tree, id)

    if siblings != [] and Enum.sum(siblings) > 1000 do
      {tree, MapSet.union(allowed, MapSet.new(Tree.iter(tree, id, ~w(table ul div section))))}
    else
      {delete_if_present(tree, id), allowed}
    end
  end

  # The first following sibling with text, then as many preceding ones as are
  # needed to reach two measurements in total.
  defp neighbour_lengths(tree, id) do
    following =
      tree
      |> Tree.next_siblings(id)
      |> Enum.map(&text_length(tree, &1))
      |> Enum.find([], &(&1 > 0))
      |> List.wrap()

    preceding =
      tree
      |> Tree.prev_siblings(id)
      |> Enum.map(&text_length(tree, &1))
      |> Enum.filter(&(&1 > 0))
      |> Enum.take(1)

    following ++ preceding
  end

  defp element_counts(tree, id) do
    counts = Map.new(@text_clean_elems, &{String.to_atom(&1), length(Tree.find_all(tree, id, &1))})
    hidden = tree |> Tree.find_all(id, "input") |> Enum.count(&(Tree.attr(tree, &1, "type") == "hidden"))

    counts
    |> Map.update!(:li, &(&1 - 100))
    |> Map.update!(:input, &(&1 - hidden))
  end

  defp candidate_score(candidates, id) do
    case candidates[id] do
      %{score: score} -> score
      nil -> 0
    end
  end

  defp count_commas(text), do: text |> String.graphemes() |> Enum.count(&(&1 == ","))

  defp delete_if_present(tree, id) do
    if Tree.exists?(tree, id), do: Tree.delete_element(tree, id), else: tree
  end
end
