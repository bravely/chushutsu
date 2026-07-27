defmodule Chushutsu.HtmlProcessing do
  @moduledoc """
  Tree-level preparation: cleaning, tag conversion and link-density filtering.

  This is the stage that turns arbitrary HTML into the small TEI-flavoured
  vocabulary the extractor works in (`p`, `head`, `list`, `item`, `quote`,
  `code`, `hi`, `ref`, `graphic`, `lb`, `table`, `row`, `cell`).
  """

  alias Chushutsu.{Deduplication, Options, Selectors, Settings, Text, Tree, URL}

  @preserve_img_cleaning ~w(figure picture source)
  @code_indicators ["{", "(\"", "('", "\n    "]

  # ## Cleaning ------------------------------------------------------------

  @doc """
  Removes unwanted elements from the tree.

  Chrome, media and interactive controls are deleted outright; presentational
  wrappers are unwrapped so their text survives. In recall mode the deletion is
  rolled back if it would leave the document without a single paragraph.
  """
  @spec tree_cleaning(Tree.t(), Tree.id(), Options.t()) :: {Tree.t(), Tree.id()}
  def tree_cleaning(tree, root, %Options{} = options) do
    {tree, cleaning_list} = table_strategy(tree, root, options)
    stripping_list = Settings.manually_stripped()

    {cleaning_list, stripping_list} =
      if options.images do
        # <img> often sits inside <figure>/<picture>/<source>; keep those wrappers
        {cleaning_list -- @preserve_img_cleaning, stripping_list -- ["img"]}
      else
        {cleaning_list, stripping_list}
      end

    tree = Tree.strip_tags(tree, root, stripping_list)
    {tree, root} = delete_listed(tree, root, cleaning_list, options)
    {prune_html(tree, root, options.focus), root}
  end

  defp table_strategy(tree, _root, %Options{tables: false}) do
    {tree, Settings.manually_cleaned() ++ ~w(table td th tr)}
  end

  defp table_strategy(tree, root, %Options{tables: true}) do
    tree =
      tree
      # a <figure> wrapping a table would otherwise take the table with it
      |> retag(root, ["figure"], &(Tree.find(&1, &2, "table") != nil))
      # ARIA explicitly marks these as layout, not data, tables
      |> retag(root, ["table"], &(Tree.attr(&1, &2, "role") in ["presentation", "none"]))

    {tree, Settings.manually_cleaned()}
  end

  defp retag(tree, root, tags, predicate) do
    tree
    |> Tree.iter(root, tags)
    |> Enum.filter(&predicate.(tree, &1))
    |> Enum.reduce(tree, &Tree.put_tag(&2, &1, "div"))
  end

  # In recall mode the cleaning is speculative: if it wipes out every paragraph
  # it has clearly over-reached, so the pre-cleaning tree is restored.
  defp delete_listed(tree, root, tags, %Options{focus: :recall} = options) do
    if Tree.find(tree, root, "p") do
      {tree, backup} = Tree.deep_copy(tree, root)
      {pruned, root} = delete_listed(tree, root, tags, %{options | focus: :balanced})

      if Tree.find(pruned, root, "p"),
        do: {pruned, root},
        else: {pruned, backup}
    else
      delete_listed(tree, root, tags, %{options | focus: :balanced})
    end
  end

  defp delete_listed(tree, root, tags, _options) do
    tree =
      Enum.reduce(tags, tree, fn tag, tree ->
        tree
        |> Tree.iter(root, [tag])
        |> Enum.reduce(tree, fn id, tree ->
          if id != root and Tree.exists?(tree, id), do: Tree.delete_element(tree, id), else: tree
        end)
      end)

    {tree, root}
  end

  @doc """
  Deletes empty elements that carry no text and no children.

  Their tails are kept except in precision mode, where a stray tail is more
  often boilerplate residue than content.
  """
  @spec prune_html(Tree.t(), Tree.id(), Options.focus()) :: Tree.t()
  def prune_html(tree, root, focus) do
    keep_tail = focus != :precision
    cut = Settings.cut_empty_elems()

    tree
    |> Tree.iter(root, cut)
    |> Enum.filter(&empty?(tree, &1))
    |> Enum.reduce(tree, fn id, tree ->
      if id != root and Tree.exists?(tree, id),
        do: Tree.delete_element(tree, id, keep_tail: keep_tail),
        else: tree
    end)
  end

  defp empty?(tree, id), do: Tree.children(tree, id) == [] and Tree.text(tree, id) in [nil, ""]

  @doc """
  Removes every section matching one of the rules.

  With `with_backup: true` the pruning is reverted when it removed almost
  everything (more than six sevenths of the text), which means the rules matched
  the content itself rather than the boilerplate around it. Returns the possibly
  swapped root along with the tree.
  """
  @spec prune_unwanted_nodes(Tree.t(), Tree.id(), [Selectors.rule()], keyword) :: {Tree.t(), Tree.id()}
  def prune_unwanted_nodes(tree, root, rules, opts \\ []) do
    if Keyword.get(opts, :with_backup, false) do
      old_len = tree |> Tree.text_content(root) |> Text.len()
      {tree, backup} = Tree.deep_copy(tree, root)
      tree = do_prune(tree, root, rules)
      new_len = tree |> Tree.text_content(root) |> Text.len()

      if new_len > old_len / 7, do: {tree, root}, else: {tree, backup}
    else
      {do_prune(tree, root, rules), root}
    end
  end

  defp do_prune(tree, root, rules) do
    Enum.reduce(rules, tree, fn rule, tree ->
      tree
      |> Selectors.select(root, rule)
      |> Enum.reduce(tree, fn id, tree ->
        if Tree.exists?(tree, id), do: Tree.delete_element(tree, id), else: tree
      end)
    end)
  end

  # ## Link density --------------------------------------------------------

  @doc """
  Summarizes the link text inside an element.

  Returns `{total_length, link_count, short_link_count, texts}`. Links shorter
  than ten characters are counted separately: a cluster of them is a navigation
  block, whatever its total length.
  """
  @spec collect_link_info(Tree.t(), [Tree.id()]) :: {non_neg_integer, non_neg_integer, non_neg_integer, [String.t()]}
  def collect_link_info(tree, link_ids) do
    texts =
      link_ids
      |> Enum.map(&Text.normalize_space(Tree.text_content(tree, &1)))
      |> Enum.reject(&(&1 == ""))

    lengths = Enum.map(texts, &Text.len/1)
    {Enum.sum(lengths), length(texts), Enum.count(lengths, &(&1 < 10)), texts}
  end

  @doc """
  Whether an element is link-dense enough to be boilerplate.

  Returns `{boilerplate?, link_texts}`; the texts feed the caller's backtracking
  check. Image containers are always spared — a gallery is mostly links by text
  measure but is still content.
  """
  @spec link_density_test(Tree.t(), Tree.id(), String.t(), boolean) :: {boolean, [String.t()]}
  def link_density_test(tree, id, text, favor_precision \\ false) do
    links = Tree.find_all(tree, id, "ref")

    cond do
      links == [] -> {false, []}
      Tree.find(tree, id, "graphic") != nil -> {false, []}
      single_dominant_link?(tree, links, text, favor_precision) -> {true, []}
      true -> density_by_size(tree, id, links, text)
    end
  end

  # One long link covering nearly the whole element: a card, not a paragraph.
  defp single_dominant_link?(tree, [link], text, favor_precision) do
    threshold = if favor_precision, do: 10, else: 100
    link_len = tree |> Tree.text_content(link) |> Text.normalize_space() |> Text.len()
    link_len > threshold and link_len > Text.len(text) * 0.9
  end

  defp single_dominant_link?(_tree, _links, _text, _favor_precision), do: false

  defp density_by_size(tree, id, links, text) do
    elem_len = Text.len(text)

    if elem_len < size_limit(tree, id) do
      {link_len, count, short, texts} = collect_link_info(tree, links)

      cond do
        count == 0 -> {true, texts}
        link_len > elem_len * 0.8 -> {true, texts}
        count > 1 and short / count > 0.8 -> {true, texts}
        true -> {false, texts}
      end
    else
      link_farm(tree, links, text)
    end
  end

  # A short element is suspicious at a much lower link ratio than a long one,
  # and the last element in a container gets more leeway (it is often a footer
  # that still holds real text).
  defp size_limit(tree, id) do
    last? = Tree.next_sibling(tree, id) == nil

    case Tree.tag(tree, id) do
      "p" -> if last?, do: 60, else: 30
      _ -> if last?, do: 300, else: 100
    end
  end

  # Large near-total-link blocks ("latest news" sidebars) sit above the size
  # gate and would otherwise never be tested. Many links is the signal: a
  # handful of long sentence-links is editorial prose.
  defp link_farm(tree, links, text) when length(links) > 4 do
    {link_len, count, _short, texts} = collect_link_info(tree, links)

    # average link length >= 100 means a catalogue (one link per card), not a farm
    if link_len > Text.len(text) * Settings.link_farm_ratio() and link_len < 100 * count,
      do: {true, texts},
      else: {false, []}
  end

  defp link_farm(_tree, _links, _text), do: {false, []}

  @doc "Whether a table is mostly links, and so boilerplate."
  @spec link_density_test_tables(Tree.t(), Tree.id()) :: boolean
  def link_density_test_tables(tree, id) do
    links = Tree.find_all(tree, id, "ref")
    elem_len = tree |> Tree.text_content(id) |> Text.normalize_space() |> Text.len()

    cond do
      links == [] ->
        false

      elem_len < 200 ->
        false

      true ->
        # links with no text (icons wrapping images) contribute nothing
        {link_len, _, _, _} = collect_link_info(tree, links)
        if elem_len < 1000, do: link_len > 0.8 * elem_len, else: link_len > 0.5 * elem_len
    end
  end

  @doc """
  Deletes elements of one tag whose link density marks them as boilerplate.

  With `backtracking: true`, shallow-but-structured elements holding link text
  are removed too, even when the density test alone would spare them.
  """
  @spec delete_by_link_density(Tree.t(), Tree.id(), String.t(), keyword) :: Tree.t()
  def delete_by_link_density(tree, root, tagname, opts \\ []) do
    backtracking = Keyword.get(opts, :backtracking, false)
    favor_precision = Keyword.get(opts, :favor_precision, false)
    len_threshold = if favor_precision, do: 200, else: 100
    depth_threshold = if favor_precision, do: 1, else: 3

    tree
    |> Tree.iter(root, [tagname])
    |> Enum.filter(fn id ->
      text = tree |> Tree.text_content(id) |> Text.normalize_space()
      {dense?, texts} = link_density_test(tree, id, text, favor_precision)

      backtrack? =
        backtracking and texts != [] and Text.len(text) > 0 and
          Text.len(text) < len_threshold and Tree.child_count(tree, id) >= depth_threshold

      (dense? or backtrack?) and not list_item_paragraph?(tree, id, tagname)
    end)
    |> Enum.reduce(tree, fn id, tree ->
      if Tree.exists?(tree, id), do: Tree.delete_element(tree, id), else: tree
    end)
  end

  # A <p> carrying a list item's content is kept: the enclosing list has its own
  # density check, and removing the paragraph here would empty the item.
  defp list_item_paragraph?(tree, id, "p") do
    Tree.tag(tree, Tree.parent(tree, id)) in ["item", "td", "th"]
  end

  defp list_item_paragraph?(_tree, _id, _tag), do: false

  # ## Text nodes ----------------------------------------------------------

  @doc """
  Normalizes a candidate text element, or rejects it.

  Returns `{tree, id}` when the element carries usable text and `{tree, nil}`
  when it should be dropped. An element with no text of its own borrows its tail,
  which is where the surrounding prose ended up after earlier tags were stripped.

  ## Options

    * `:comments_fix` — turn a bare `lb` into a paragraph (default `true`)
    * `:preserve_spaces` — skip whitespace collapsing
  """
  @spec handle_textnode(Tree.t(), Tree.id(), Options.t(), keyword) :: {Tree.t(), Tree.id() | nil}
  def handle_textnode(tree, id, options), do: do_handle_textnode(tree, id, options, true, false)

  def handle_textnode(tree, id, options, opts) do
    do_handle_textnode(
      tree,
      id,
      options,
      Keyword.get(opts, :comments_fix, true),
      Keyword.get(opts, :preserve_spaces, false)
    )
  end

  defp do_handle_textnode(tree, id, options, comments_fix, preserve_spaces) do
    cond do
      Tree.tag(tree, id) == "graphic" and image_element?(tree, id) ->
        {tree, id}

      Tree.tag(tree, id) == "done" or empty_node?(tree, id) ->
        {tree, nil}

      not comments_fix and Tree.tag(tree, id) == "lb" ->
        {maybe_trim_tail(tree, id, preserve_spaces), id}

      true ->
        tree
        |> borrow_tail(id, comments_fix)
        |> trim_node(id, preserve_spaces)
        |> filter_node(id, options)
    end
  end

  defp empty_node?(tree, id) do
    Tree.children(tree, id) == [] and Tree.text(tree, id) in [nil, ""] and
      Tree.tail(tree, id) in [nil, ""]
  end

  defp maybe_trim_tail(tree, _id, true), do: tree

  defp maybe_trim_tail(tree, id, false),
    do: Tree.put_tail(tree, id, presence(Text.normalize_space(Tree.tail(tree, id))))

  defp borrow_tail(tree, id, comments_fix) do
    if Tree.text(tree, id) in [nil, ""] and Tree.children(tree, id) == [] do
      tree = tree |> Tree.put_text(id, Tree.tail(tree, id)) |> Tree.put_tail(id, "")
      if comments_fix and Tree.tag(tree, id) == "lb", do: Tree.put_tag(tree, id, "p"), else: tree
    else
      tree
    end
  end

  defp trim_node(tree, _id, true), do: tree

  defp trim_node(tree, id, false) do
    tree = Tree.put_text(tree, id, presence(Text.normalize_space(Tree.text(tree, id))))

    case Tree.tail(tree, id) do
      tail when tail in [nil, ""] -> tree
      tail -> Tree.put_tail(tree, id, presence(Text.normalize_space(tail)))
    end
  end

  defp filter_node(tree, id, options) do
    dropped? =
      (Tree.text(tree, id) in [nil, ""] and textfilter?(tree, id)) or
        (options.dedup and Deduplication.duplicate?(tree, id, options))

    {tree, if(dropped?, do: nil, else: id)}
  end

  @doc """
  A lighter variant of `handle_textnode/4` for elements read as plain text.

  Text and tail are always trimmed, and an element with only a tail is rewritten
  to carry it as its text.
  """
  @spec process_node(Tree.t(), Tree.id(), Options.t()) :: {Tree.t(), Tree.id() | nil}
  def process_node(tree, id, options) do
    if Tree.tag(tree, id) == "done" or empty_node?(tree, id) do
      {tree, nil}
    else
      tree =
        tree
        |> Tree.put_text(id, presence(Text.normalize_space(Tree.text(tree, id))))
        |> Tree.put_tail(id, presence(Text.normalize_space(Tree.tail(tree, id))))
        |> promote_tail(id)

      if has_content?(tree, id) and rejected?(tree, id, options),
        do: {tree, nil},
        else: {tree, id}
    end
  end

  defp promote_tail(tree, id) do
    if Tree.tag(tree, id) != "lb" and Tree.text(tree, id) in [nil, ""] and
         Tree.tail(tree, id) not in [nil, ""] do
      tree |> Tree.put_text(id, Tree.tail(tree, id)) |> Tree.put_tail(id, nil)
    else
      tree
    end
  end

  defp has_content?(tree, id),
    do: Tree.text(tree, id) not in [nil, ""] or Tree.tail(tree, id) not in [nil, ""]

  defp rejected?(tree, id, options) do
    textfilter?(tree, id) or (options.dedup and Deduplication.duplicate?(tree, id, options))
  end

  @doc "Whether an element's text is share/social boilerplate."
  @spec textfilter?(Tree.t(), Tree.id()) :: boolean
  def textfilter?(tree, id) do
    test_text = if Tree.text(tree, id) == nil, do: Tree.tail(tree, id), else: Tree.text(tree, id)

    test_text in [nil, ""] or Text.blank?(test_text) or Text.filtered?(test_text)
  end

  @doc "Whether a `graphic` element points at something that looks like an image."
  @spec image_element?(Tree.t(), Tree.id()) :: boolean
  def image_element?(tree, id) do
    Enum.any?(["data-src", "src"], &Text.image_file?(Tree.attr(tree, id, &1))) or
      Enum.any?(Tree.attrs(tree, id), fn {name, value} ->
        String.starts_with?(name, "data-src") and Text.image_file?(value)
      end)
  end

  defp presence(""), do: nil
  defp presence(value), do: value

  # ## Tag conversion ------------------------------------------------------

  @conversions %{
    "dl" => :list,
    "ol" => :list,
    "ul" => :list,
    "h1" => :heading,
    "h2" => :heading,
    "h3" => :heading,
    "h4" => :heading,
    "h5" => :heading,
    "h6" => :heading,
    "br" => :line_break,
    "hr" => :line_break,
    "blockquote" => :quote,
    "pre" => :quote,
    "q" => :quote,
    "del" => :deletion,
    "s" => :deletion,
    "strike" => :deletion,
    "details" => :details
  }

  @doc """
  Rewrites HTML markup into the extractor's internal vocabulary.

  Links become `ref`, headings `head`, lists `list`/`item`, quotes `quote` or
  `code`, line breaks `lb`, images `graphic`, and formatting tags either collapse
  into `hi` (when formatting is kept) or are stripped entirely.
  """
  @spec convert_tags(Tree.t(), Tree.id(), Options.t(), String.t() | nil) :: Tree.t()
  def convert_tags(tree, root, %Options{} = options, url \\ nil) do
    tree
    |> convert_links(root, options, url)
    |> convert_faq_questions(root)
    |> convert_formatting(root, options)
    |> apply_conversions(root)
    |> convert_images(root, options)
  end

  # Without link support, anchors inside content blocks are still renamed so the
  # density heuristics can see them; the rest are unwrapped.
  defp convert_links(tree, root, %Options{links: false} = options, _url) do
    containers = if options.tables, do: ~w(div li p table), else: ~w(div li p)

    tree
    |> Tree.iter(root, containers)
    |> Enum.flat_map(&Tree.find_all(tree, &1, "a"))
    |> Enum.uniq()
    |> Enum.reduce(tree, &Tree.put_tag(&2, &1, "ref"))
    |> Tree.strip_tags(root, ["a"])
  end

  defp convert_links(tree, root, %Options{links: true}, url) do
    base = URL.base_url(url)

    tree
    |> Tree.iter(root, ["a", "ref"])
    |> Enum.reduce(tree, fn id, tree ->
      target = Tree.attr(tree, id, "href") || Tree.attr(tree, id, "target")
      tree = tree |> Tree.put_tag(id, "ref") |> Tree.clear_attrs(id)

      if target in [nil, ""],
        do: tree,
        else: Tree.put_attr(tree, id, "target", URL.absolutize(target, base))
    end)
  end

  # Yoast FAQ blocks mark questions with bold text that functions as a heading.
  defp convert_faq_questions(tree, root) do
    tree
    |> Tree.iter(root, ["strong"])
    |> Enum.filter(&String.contains?(Tree.attr(tree, &1, "class", ""), "schema-faq-question"))
    |> Enum.reduce(tree, fn id, tree ->
      tree |> Tree.put_attrs(id, [{"rend", "h3"}]) |> Tree.put_tag(id, "head")
    end)
  end

  defp convert_formatting(tree, root, %Options{formatting: true}) do
    mapping = Settings.rend_tag_mapping()

    tree
    |> Tree.iter(root, Map.keys(mapping))
    |> Enum.reduce(tree, fn id, tree ->
      rend = Map.fetch!(mapping, Tree.tag(tree, id))
      tree |> Tree.put_attrs(id, [{"rend", rend}]) |> Tree.put_tag(id, "hi")
    end)
  end

  defp convert_formatting(tree, root, %Options{formatting: false}) do
    Tree.strip_tags(tree, root, Map.keys(Settings.rend_tag_mapping()))
  end

  defp apply_conversions(tree, root) do
    tree
    |> Tree.iter(root, Map.keys(@conversions))
    |> Enum.reduce(tree, fn id, tree ->
      case Map.get(@conversions, Tree.tag(tree, id)) do
        nil -> tree
        conversion -> convert(conversion, tree, id)
      end
    end)
  end

  defp convert(:list, tree, id) do
    tree = tree |> Tree.put_attr(id, "rend", Tree.tag(tree, id)) |> Tree.put_tag(id, "list")

    # <dd>/<dt> pairs are numbered so the serializer can keep them associated
    {tree, _counter} =
      tree
      |> Tree.iter(id, ~w(dd dt li))
      |> Enum.reduce({tree, 1}, fn item, {tree, counter} ->
        tag = Tree.tag(tree, item)

        tree =
          if tag in ["dd", "dt"],
            do: Tree.put_attr(tree, item, "rend", "#{tag}-#{counter}"),
            else: tree

        {Tree.put_tag(tree, item, "item"), if(tag == "dd", do: counter + 1, else: counter)}
      end)

    tree
  end

  defp convert(:heading, tree, id) do
    tree
    |> Tree.put_attrs(id, [{"rend", Tree.tag(tree, id)}])
    |> Tree.put_tag(id, "head")
  end

  defp convert(:line_break, tree, id), do: Tree.put_tag(tree, id, "lb")

  defp convert(:deletion, tree, id) do
    tree |> Tree.put_tag(id, "del") |> Tree.put_attr(id, "rend", "overstrike")
  end

  defp convert(:details, tree, id) do
    tree
    |> Tree.put_tag(id, "div")
    |> then(fn tree ->
      tree
      |> Tree.iter(id, ["summary"])
      |> Enum.reduce(tree, &Tree.put_tag(&2, &1, "head"))
    end)
  end

  defp convert(:quote, tree, id) do
    if Tree.tag(tree, id) == "pre" and code_block?(tree, id) do
      tree |> clear_hljs_attrs(id) |> Tree.put_tag(id, "code")
    else
      Tree.put_tag(tree, id, "quote")
    end
  end

  # A <pre> is treated as code when it is syntax-highlighted, wraps a lone span,
  # or its text carries obvious code punctuation.
  defp code_block?(tree, id) do
    children = Tree.children(tree, id)

    (match?([_], children) and Tree.tag(tree, hd(children)) == "span") or
      hljs_spans(tree, id) != [] or
      code_indicators?(Tree.text(tree, id))
  end

  defp hljs_spans(tree, id) do
    tree
    |> Tree.find_all(id, "span")
    |> Enum.filter(&String.starts_with?(Tree.attr(tree, &1, "class", ""), "hljs"))
  end

  defp clear_hljs_attrs(tree, id) do
    tree |> hljs_spans(id) |> Enum.reduce(tree, &Tree.clear_attrs(&2, &1))
  end

  defp code_indicators?(nil), do: false
  defp code_indicators?(text), do: Enum.any?(@code_indicators, &String.contains?(text, &1))

  defp convert_images(tree, _root, %Options{images: false}), do: tree

  defp convert_images(tree, root, %Options{images: true} = options) do
    tree =
      tree
      |> Tree.iter(root, ["img"])
      |> Enum.reduce(tree, &Tree.put_tag(&2, &1, "graphic"))

    if options.links, do: lift_images_out_of_links(tree, root), else: tree
  end

  # An image inside a link would otherwise be swallowed when the link is
  # rendered as inline text, so it is moved out to become its own element.
  defp lift_images_out_of_links(tree, root) do
    tree
    |> Tree.iter(root, ["ref"])
    |> Enum.reduce(tree, fn ref, tree ->
      case Tree.find_all(tree, ref, "graphic") do
        [] ->
          tree

        graphics ->
          # reversed so each insertion lands before the previous one
          tree = Enum.reduce(Enum.reverse(graphics), tree, &Tree.insert_after(&2, ref, &1))

          if Text.normalize_space(Tree.text_content(tree, ref)) == "",
            do: Tree.delete_element(tree, ref),
            else: tree
      end
    end)
  end
end
