defmodule Chushutsu.MainExtractor do
  @moduledoc """
  Trafilatura's own extractor: locate the content area, then rewrite it.

  Every handler takes `{tree, id}` and returns `{tree, new_id | nil}` — `nil`
  meaning "this element contributed nothing". Handlers build *new* elements
  rather than editing in place, and mark the source elements `"done"` so a later
  pass cannot pick the same content up twice.
  """

  alias Chushutsu.{HtmlProcessing, Options, Selectors, Settings, Text, Tree}

  @p_formatting ~w(hi ref)
  @table_elems ~w(td th)
  @inline_wrap_tags @p_formatting ++ ["del"]
  @formatting @p_formatting ++ ~w(del span)
  @codes_quotes ~w(code quote)
  @not_at_the_end ~w(head ref)

  # Internal attributes worth carrying onto a rewired element; everything else
  # (stray class/style/width) is dropped.
  @keep_attrs ~w(rend role target src alt title)

  @max_span 100

  # Resolved at compile time; see the note in Chushutsu.Serialize.Text.
  @tag_catalog Settings.tag_catalog()
  @inline_carried Settings.inline_carried()
  @formatting_protected Settings.formatting_protected()
  # tags permitted inside a quoted paragraph
  @quote_tags Settings.tag_catalog() ++ ["ref", "graphic"]
  @min_duplicate_length Settings.min_duplicate_length()
  @dedupe_scan_cap Settings.dedupe_scan_cap()

  # ## Entry points --------------------------------------------------------

  @doc """
  Extracts the main content, returning `{tree, body_id, text, length}`.

  Runs the content-area cascade first; if that comes up short, falls back to
  sweeping the whole document for stray text elements.
  """
  @spec extract_content(Tree.t(), Tree.id(), Options.t()) ::
          {Tree.t(), Tree.id(), String.t(), non_neg_integer}
  def extract_content(tree, root, %Options{} = options) do
    {tree, backup} = Tree.deep_copy(tree, root)
    {tree, body, text, potential_tags} = extract_from_regions(tree, root, options)

    {tree, body, text} =
      if Tree.children(tree, body) == [] or Text.len(text) < options.min_extracted_size do
        {tree, body} = recover_wild_text(tree, backup, body, options, potential_tags)
        {tree, body, body_text(tree, body)}
      else
        {tree, body, text}
      end

    tree =
      tree
      |> drop_adjacent_repeats(body)
      |> Tree.strip_elements(body, ["done"])
      |> Tree.strip_tags(body, ["div"])

    {tree, body, text, Text.len(text)}
  end

  @doc """
  Extracts comments, returning `{tree, body_id, text, length}`.

  The matched comment section is removed from `tree`, so the caller's subsequent
  body extraction cannot pick the same text up again.
  """
  @spec extract_comments(Tree.t(), Tree.id(), Options.t()) ::
          {Tree.t(), Tree.id(), String.t(), non_neg_integer}
  def extract_comments(tree, root, %Options{} = options) do
    {tree, body} = Tree.create(tree, "body")
    potential_tags = @tag_catalog

    {tree, body} =
      Enum.reduce_while(Selectors.comments(), {tree, body}, fn rule, {tree, body} ->
        case Selectors.select_first(tree, root, rule) do
          nil -> {:cont, {tree, body}}
          subtree -> collect_comments(tree, subtree, body, potential_tags, options)
        end
      end)

    text = body_text(tree, body)
    {tree, body, text, Text.len(text)}
  end

  defp collect_comments(tree, subtree, body, potential_tags, options) do
    {tree, subtree} = HtmlProcessing.prune_unwanted_nodes(tree, subtree, Selectors.comments_discard())
    tree = Tree.strip_tags(tree, subtree, ~w(a ref span))

    {tree, body} =
      tree
      |> Tree.iterdescendants(subtree)
      |> Enum.reduce({tree, body}, fn id, {tree, body} ->
        case process_comments_node(tree, id, potential_tags, options) do
          {tree, nil} -> {tree, body}
          {tree, processed} -> {Tree.append(tree, body, processed), body}
        end
      end)

    if Tree.children(tree, body) == [] do
      {:cont, {tree, body}}
    else
      {:halt, {Tree.delete_element(tree, subtree, keep_tail: false), body}}
    end
  end

  defp process_comments_node(tree, id, potential_tags, options) do
    if Tree.tag(tree, id) in potential_tags do
      case HtmlProcessing.handle_textnode(tree, id, options, comments_fix: true) do
        {tree, nil} -> {tree, nil}
        {tree, processed} -> {Tree.clear_attrs(tree, processed), processed}
      end
    else
      {tree, nil}
    end
  end

  # ## The content-area cascade --------------------------------------------

  defp extract_from_regions(tree, root, options) do
    {tree, body} = Tree.create(tree, "body")
    potential_tags = initial_potential_tags(options)

    {tree, body, potential_tags} =
      Enum.reduce_while(Selectors.content(), {tree, body, potential_tags}, fn rule, acc ->
        {tree, body, potential_tags} = acc

        case Selectors.select_first(tree, root, rule) do
          nil -> {:cont, acc}
          subtree -> harvest_region(tree, subtree, body, potential_tags, options)
        end
      end)

    {tree, body, body_text(tree, body), potential_tags}
  end

  defp initial_potential_tags(options) do
    @tag_catalog
    |> maybe_add(options.tables, ~w(table td th tr))
    |> maybe_add(options.images, ["graphic"])
    |> maybe_add(options.links, ["ref"])
  end

  defp maybe_add(tags, true, extra), do: tags ++ extra
  defp maybe_add(tags, false, _extra), do: tags

  defp harvest_region(tree, subtree, body, potential_tags, options) do
    {tree, subtree} = prune_unwanted_sections(tree, subtree, potential_tags, options)

    if Tree.children(tree, subtree) == [] do
      {:cont, {tree, body, potential_tags}}
    else
      potential_tags = widen_for_sparse_paragraphs(tree, subtree, potential_tags, options)
      tree = strip_unwanted_inline(tree, subtree, potential_tags)

      {tree, body} = append_handled(tree, subtree, body, potential_tags, options)
      tree = drop_trailing_titles(tree, body)

      if real_content?(tree, body),
        do: {:halt, {tree, body, potential_tags}},
        else: {:cont, {tree, body, potential_tags}}
    end
  end

  # A region with little paragraph text is probably built out of divs, so divs
  # become eligible content. The measure is taken over the whole document the
  # region belongs to, matching the absolute `//p//text()` used upstream.
  defp widen_for_sparse_paragraphs(tree, subtree, potential_tags, options) do
    document = tree |> Tree.ancestors(subtree) |> List.last() || subtree
    factor = if options.focus == :precision, do: 1, else: 3

    paragraph_text =
      tree
      |> Tree.find_all(document, "p")
      |> Enum.map_join("", &Tree.text_content(tree, &1))

    if Text.len(paragraph_text) < options.min_extracted_size * factor,
      do: Enum.uniq(potential_tags ++ ["div"]),
      else: potential_tags
  end

  defp strip_unwanted_inline(tree, subtree, potential_tags) do
    tree
    |> then(&if("ref" in potential_tags, do: &1, else: Tree.strip_tags(&1, subtree, ["ref"])))
    |> then(&if("span" in potential_tags, do: &1, else: Tree.strip_tags(&1, subtree, ["span"])))
  end

  defp append_handled(tree, subtree, body, potential_tags, options) do
    candidates = Tree.iterdescendants(tree, subtree)

    # A region holding nothing but line breaks has all its text in tails;
    # handing over the region itself is the only way to reach it.
    candidates =
      if candidates != [] and Enum.all?(candidates, &(Tree.tag(tree, &1) == "lb")),
        do: [subtree],
        else: candidates

    Enum.reduce(candidates, {tree, body}, fn id, {tree, body} ->
      case handle_textelem(tree, id, potential_tags, options) do
        {tree, nil} -> {tree, body}
        {tree, processed} -> {Tree.append(tree, body, processed), body}
      end
    end)
  end

  defp drop_trailing_titles(tree, body) do
    case List.last(Tree.children(tree, body)) do
      nil ->
        tree

      last ->
        if Tree.tag(tree, last) in @not_at_the_end,
          do: drop_trailing_titles(Tree.delete_element(tree, last, keep_tail: false), body),
          else: tree
    end
  end

  # More than one non-image element means the region really carried content;
  # a lone image is not enough to stop the cascade.
  defp real_content?(tree, body) do
    tree
    |> Tree.children(body)
    |> Enum.count(&(Tree.tag(tree, &1) != "graphic"))
    |> Kernel.>(1)
  end

  # ## Pruning -------------------------------------------------------------

  @doc """
  Rule-based removal of boilerplate from a candidate region.

  Returns the possibly-swapped region root along with the tree, since the
  backed-up prune can decide to discard its own result.
  """
  @spec prune_unwanted_sections(Tree.t(), Tree.id(), [String.t()], Options.t(), keyword) ::
          {Tree.t(), Tree.id()}
  def prune_unwanted_sections(tree, root, potential_tags, options, opts \\ []) do
    favor_precision = options.focus == :precision
    keep_teasers = Keyword.get(opts, :keep_teasers, false)

    {tree, root} =
      HtmlProcessing.prune_unwanted_nodes(tree, root, Selectors.overall_discard(), with_backup: true)

    {tree, root} =
      if "graphic" in potential_tags,
        do: {tree, root},
        else: HtmlProcessing.prune_unwanted_nodes(tree, root, Selectors.image_discard())

    {tree, root} = prune_for_balance(tree, root, options, keep_teasers, favor_precision)

    tree
    |> prune_link_dense(root, favor_precision)
    |> prune_boilerplate_tables(root, potential_tags, favor_precision)
    |> prune_for_precision(root, favor_precision)
    |> then(&{&1, root})
  end

  defp prune_for_balance(tree, root, %Options{focus: :recall}, _keep_teasers, _fp), do: {tree, root}

  defp prune_for_balance(tree, root, _options, keep_teasers, favor_precision) do
    {tree, root} =
      if keep_teasers,
        do: {tree, root},
        else: HtmlProcessing.prune_unwanted_nodes(tree, root, Selectors.teaser_discard())

    if favor_precision,
      do: HtmlProcessing.prune_unwanted_nodes(tree, root, Selectors.precision_discard()),
      else: {tree, root}
  end

  # Two passes: removing a container can expose a newly-thin parent.
  defp prune_link_dense(tree, root, favor_precision) do
    Enum.reduce(1..2, tree, fn _pass, tree ->
      tree
      |> HtmlProcessing.delete_by_link_density(root, "div", backtracking: true, favor_precision: favor_precision)
      |> HtmlProcessing.delete_by_link_density(root, "list", favor_precision: favor_precision)
      |> HtmlProcessing.delete_by_link_density(root, "p", favor_precision: favor_precision)
    end)
  end

  defp prune_boilerplate_tables(tree, root, potential_tags, favor_precision) do
    if "table" in potential_tags or favor_precision do
      # collected before deleting: removing a table mid-walk can hide the next one
      tree
      |> Tree.iter(root, ["table"])
      |> Enum.filter(&HtmlProcessing.link_density_test_tables(tree, &1))
      |> Enum.reduce(tree, fn id, tree ->
        if Tree.exists?(tree, id), do: Tree.delete_element(tree, id, keep_tail: false), else: tree
      end)
    else
      tree
    end
  end

  defp prune_for_precision(tree, _root, false), do: tree

  defp prune_for_precision(tree, root, true) do
    tree
    |> drop_trailing_heads(root)
    |> HtmlProcessing.delete_by_link_density(root, "head", favor_precision: true)
    |> HtmlProcessing.delete_by_link_density(root, "quote", favor_precision: true)
  end

  defp drop_trailing_heads(tree, root) do
    case List.last(Tree.children(tree, root)) do
      nil ->
        tree

      last ->
        if Tree.tag(tree, last) == "head",
          do: drop_trailing_heads(Tree.delete_element(tree, last, keep_tail: false), root),
          else: tree
    end
  end

  # ## Wild-text recovery --------------------------------------------------

  @doc """
  Last-resort sweep for text the region cascade missed.

  Runs over the pre-extraction backup, including material outside whatever frame
  was chosen. Deliberately narrow: extra recovered text raises the measured
  length, which can suppress the stronger rescues that run after this one.
  """
  @spec recover_wild_text(Tree.t(), Tree.id(), Tree.id(), Options.t(), [String.t()]) ::
          {Tree.t(), Tree.id()}
  def recover_wild_text(tree, source, body, options, potential_tags) do
    potential_tags =
      if options.focus == :recall,
        do: Enum.uniq(potential_tags ++ ["div", "lb"]),
        else: potential_tags

    # In fast mode there is no external comparator to defer to, so teaser blocks
    # — some of which are real content — are kept on this last-resort path.
    {tree, search_root} =
      prune_unwanted_sections(tree, source, potential_tags, options, keep_teasers: options.fast)

    unwanted = if "ref" in potential_tags, do: ["span"], else: ~w(a ref span)
    tree = Tree.strip_tags(tree, search_root, unwanted)

    candidates = wild_text_candidates(tree, search_root, options.focus == :recall)
    seen = existing_texts(tree, body)

    {tree, body, _seen} =
      Enum.reduce(candidates, {tree, body, seen}, fn id, {tree, body, seen} ->
        absorb_candidate(tree, id, body, seen, potential_tags, options)
      end)

    {tree, body}
  end

  # blockquote/pre/q are already `quote`/`code` by the time this runs
  defp wild_text_candidates(tree, root, recall?) do
    base = ~w(code p quote table)
    tags = if recall?, do: base ++ ~w(div lb list), else: base

    tree
    |> Tree.iterdescendants(root, tags)
    |> Enum.filter(fn id ->
      Tree.tag(tree, id) != "div" or recall? or
        String.contains?(Tree.attr(tree, id, "class", ""), "w3-code")
    end)
  end

  defp absorb_candidate(tree, id, body, {texts, joined}, potential_tags, options) do
    case handle_textelem(tree, id, potential_tags, options) do
      {tree, nil} ->
        {tree, body, {texts, joined}}

      {tree, processed} ->
        text = elem_text(tree, processed)

        if duplicate_of_existing?(text, texts, joined) do
          {tree, body, {texts, joined}}
        else
          tree = Tree.append(tree, body, processed)
          {tree, body, remember(text, texts, joined)}
        end
    end
  end

  # An exact repeat of an element already taken, or — for longer runs — a
  # substring of the accumulated text (a <p> folded into its <list> container).
  defp duplicate_of_existing?(text, texts, joined) do
    text != "" and
      (MapSet.member?(texts, text) or
         (Text.len(text) > @min_duplicate_length and under_cap?(joined) and
            String.contains?(joined, text)))
  end

  defp remember(text, texts, joined) do
    joined = if under_cap?(joined), do: joined <> "\n" <> text, else: joined
    {MapSet.put(texts, text), joined}
  end

  defp under_cap?(joined), do: Text.len(joined) <= @dedupe_scan_cap

  # Newline-joined, since trimmed element text never contains one — that way no
  # substring match can straddle two elements.
  defp existing_texts(tree, body) do
    texts = tree |> Tree.children(body) |> Enum.map(&elem_text(tree, &1))
    {MapSet.new(texts), texts |> Enum.reject(&(&1 == "")) |> Enum.join("\n")}
  end

  # Substantial elements repeating the one before them are recovery artifacts.
  # Length-gated so short genuine repeats survive.
  defp drop_adjacent_repeats(tree, body) do
    tree
    |> Tree.children(body)
    |> Enum.reduce({tree, nil}, fn id, {tree, previous} ->
      current = elem_text(tree, id)

      if current != "" and current == previous and
           Text.len(current) > @min_duplicate_length do
        {Tree.delete_element(tree, id, keep_tail: false), previous}
      else
        {tree, current}
      end
    end)
    |> elem(0)
  end

  # ## Element dispatch ----------------------------------------------------

  @doc "Routes an element to the handler for its tag."
  @spec handle_textelem(Tree.t(), Tree.id(), [String.t()], Options.t()) :: {Tree.t(), Tree.id() | nil}
  def handle_textelem(tree, id, potential_tags, options) do
    case Tree.tag(tree, id) do
      "list" -> handle_lists(tree, id, options)
      tag when tag in @codes_quotes -> handle_quotes(tree, id, options)
      "head" -> handle_titles(tree, id, options)
      "p" -> handle_paragraphs(tree, id, potential_tags, options)
      "lb" -> handle_line_break(tree, id, options)
      tag when tag in @formatting -> handle_formatting(tree, id, options)
      "table" -> if "table" in potential_tags, do: handle_table(tree, id, potential_tags, options), else: {tree, nil}
      "graphic" -> if "graphic" in potential_tags, do: handle_image(tree, id, options), else: {tree, nil}
      _ -> handle_other_elements(tree, id, potential_tags, options)
    end
  end

  # ## Titles --------------------------------------------------------------

  defp handle_titles(tree, id, options) do
    {tree, title} =
      if Tree.children(tree, id) == [] do
        HtmlProcessing.process_node(tree, id, options)
      else
        build_title_from_children(tree, id, options)
      end

    if title && Text.text_chars?(Enum.join(Tree.itertext(tree, title))),
      do: {tree, title},
      else: {tree, nil}
  end

  defp build_title_from_children(tree, id, options) do
    {tree, title} = Tree.deep_copy(tree, id)

    tree
    |> Tree.children(id)
    |> Enum.reduce({tree, title}, fn child, {tree, title} ->
      {tree, processed} = HtmlProcessing.handle_textnode(tree, child, options, comments_fix: false)
      tree = if processed, do: Tree.append(tree, title, processed), else: tree
      {Tree.put_tag(tree, child, "done"), title}
    end)
  end

  # ## Formatting ----------------------------------------------------------

  defp handle_formatting(tree, id, options) do
    case HtmlProcessing.process_node(tree, id, options) do
      {tree, nil} ->
        {tree, nil}

      {tree, formatting} ->
        anchor = Tree.parent(tree, id) || Tree.prev_sibling(tree, id)

        if anchor && Tree.tag(tree, anchor) in @formatting_protected do
          {tree, formatting}
        else
          # an orphan inline run needs a block to live in
          {tree, wrapper} = Tree.create(tree, "p")
          {Tree.insert(tree, wrapper, 0, formatting), wrapper}
        end
    end
  end

  # ## Lists ---------------------------------------------------------------

  defp handle_lists(tree, id, options) do
    {tree, processed} = Tree.create(tree, Tree.tag(tree, id))

    # loose text before the first <li> still belongs to the list
    {tree, processed} =
      if Text.text_chars?(Tree.text(tree, id)) do
        {tree, first} = Tree.create_child(tree, processed, "item")
        {Tree.put_text(tree, first, Tree.text(tree, id)), processed}
      else
        {tree, processed}
      end

    {tree, processed} =
      tree
      |> Tree.iterdescendants(id, ["item"])
      |> Enum.reduce({tree, processed}, fn child, {tree, processed} ->
        {tree, item} = build_list_item(tree, child, processed, options)

        tree =
          if Tree.text(tree, item) not in [nil, ""] or Tree.children(tree, item) != [] do
            tree |> copy_rendition(child, item) |> Tree.append(processed, item)
          else
            tree
          end

        {Tree.put_tag(tree, child, "done"), processed}
      end)

    tree = Tree.put_tag(tree, id, "done")

    if text_element?(tree, processed),
      do: {copy_rendition(tree, id, processed), processed},
      else: {tree, nil}
  end

  defp build_list_item(tree, child, processed, options) do
    {tree, item} = Tree.create(tree, "item")

    if Tree.children(tree, child) == [] do
      case HtmlProcessing.process_node(tree, child, options) do
        {tree, nil} ->
          {tree, item}

        {tree, node} ->
          text = Tree.text(tree, node) || ""
          tail = Tree.tail(tree, node)
          text = if Text.text_chars?(tail), do: text <> " " <> tail, else: text
          {Tree.append(Tree.put_text(tree, item, text), processed, item), item}
      end
    else
      tree = process_nested_elements(tree, child, item, options)
      {carry_item_tail(tree, child, item), item}
    end
  end

  # Text after </li> belongs to the item's last child, not to the next item.
  defp carry_item_tail(tree, child, item) do
    tail = Tree.tail(tree, child)

    with true <- Text.text_chars?(tail),
         [_ | _] = kids <- Enum.reject(Tree.children(tree, item), &(Tree.tag(tree, &1) == "done")) do
      last = List.last(kids)

      case Tree.tail(tree, last) do
        existing when existing in [nil, ""] -> Tree.put_tail(tree, last, tail)
        existing -> Tree.put_tail(tree, last, existing <> " " <> tail)
      end
    else
      _ -> tree
    end
  end

  defp process_nested_elements(tree, child, target, options) do
    tree = Tree.put_text(tree, target, Tree.text(tree, child))

    tree
    |> Tree.iterdescendants(child)
    |> Enum.reduce(tree, fn subelem, tree ->
      tree =
        cond do
          Tree.tag(tree, subelem) == "list" ->
            case handle_lists(tree, subelem, options) do
              {tree, nil} -> tree
              {tree, sublist} -> Tree.append(tree, target, sublist)
            end

          Tree.tag(tree, subelem) in @inline_carried ->
            {tree, _} = define_newelem(tree, subelem, target, keep_children: true)
            tree

          true ->
            case HtmlProcessing.handle_textnode(tree, subelem, options, comments_fix: false) do
              {tree, nil} -> tree
              {tree, processed} -> define_newelem(tree, processed, target) |> elem(0)
            end
        end

      Tree.put_tag(tree, subelem, "done")
    end)
  end

  # ## Quotes and code -----------------------------------------------------

  defp handle_quotes(tree, id, options) do
    if code_block_element?(tree, id) do
      handle_code_blocks(tree, id)
    else
      build_quote(tree, id, options)
    end
  end

  defp code_block_element?(tree, id) do
    parent = Tree.parent(tree, id)
    inner_code = tree |> Tree.find_children(id, "code") |> List.first()

    Tree.attr(tree, id, "lang") != nil or Tree.tag(tree, id) == "code" or
      (parent && String.contains?(Tree.attr(tree, parent, "class", ""), "highlight")) or
      (inner_code != nil and Tree.child_count(tree, id) == 1 and
         Text.trim(Tree.text(tree, id)) == "" and Text.trim(Tree.tail(tree, inner_code)) == "")
  end

  defp handle_code_blocks(tree, id) do
    {tree, copy} = Tree.deep_copy(tree, id)
    tree = tree |> Tree.put_tag_all(Tree.iter(tree, id), "done") |> Tree.put_tag(copy, "code")
    {tree, copy}
  end

  defp build_quote(tree, id, options) do
    {tree, processed} = Tree.create(tree, Tree.tag(tree, id))
    tree = Tree.put_text(tree, processed, Tree.text(tree, id))

    tree =
      tree
      |> Tree.iterdescendants(id)
      |> Enum.reduce(tree, fn child, tree ->
        tree
        |> absorb_quote_child(child, processed, options)
        |> Tree.put_tag(child, "done")
      end)

    if text_element?(tree, processed),
      # collapse nested quotes rather than emit quote-in-quote
      do: {Tree.strip_tags(tree, processed, ["quote"]), processed},
      else: {tree, nil}
  end

  defp absorb_quote_child(tree, child, processed, options) do
    cond do
      Tree.tag(tree, child) == "graphic" ->
        case handle_image(tree, child, options) do
          {tree, nil} -> tree
          {tree, image} -> define_newelem(tree, image, processed) |> elem(0)
        end

      Tree.tag(tree, child) == "p" and Tree.children(tree, child) != [] ->
        case handle_paragraphs(tree, child, @quote_tags, options) do
          {tree, nil} -> tree
          {tree, paragraph} -> Tree.append(tree, processed, paragraph)
        end

      Tree.tag(tree, child) in @inline_carried ->
        define_newelem(tree, child, processed, keep_children: true) |> elem(0)

      true ->
        case HtmlProcessing.process_node(tree, child, options) do
          {tree, nil} -> tree
          {tree, node} -> define_newelem(tree, node, processed) |> elem(0)
        end
    end
  end

  # ## Paragraphs ----------------------------------------------------------

  defp handle_paragraphs(tree, id, potential_tags, options) do
    tree = Tree.clear_attrs(tree, id)

    if Tree.children(tree, id) == [] do
      HtmlProcessing.process_node(tree, id, options)
    else
      build_paragraph(tree, id, potential_tags, options)
    end
  end

  defp build_paragraph(tree, id, potential_tags, options) do
    {tree, processed} = Tree.create(tree, Tree.tag(tree, id))

    # iter/1 includes the paragraph itself, which is how its own text gets in
    tree =
      tree
      |> Tree.iter(id)
      |> Enum.reduce(tree, fn child, tree ->
        if Tree.tag(tree, child) in potential_tags or Tree.tag(tree, child) == "done" do
          absorb_paragraph_child(tree, child, processed, options)
        else
          tree
        end
      end)

    finish_paragraph(tree, processed)
  end

  defp absorb_paragraph_child(tree, child, processed, options) do
    case HtmlProcessing.handle_textnode(tree, child, options, comments_fix: false, preserve_spaces: true) do
      {tree, nil} ->
        Tree.put_tag(tree, child, "done")

      {tree, node} ->
        tree
        |> merge_or_append(child, node, processed, options)
        |> Tree.put_tag(child, "done")
    end
  end

  defp merge_or_append(tree, child, node, processed, options) do
    cond do
      # a nested paragraph's text folds into the outer one
      Tree.tag(tree, node) == "p" ->
        merge_paragraph_text(tree, node, processed)

      Tree.tag(tree, node) in @p_formatting and wraps_inline?(tree, node) ->
        define_newelem(tree, node, processed, keep_children: true) |> elem(0)

      true ->
        append_paragraph_child(tree, child, node, processed, options)
    end
  end

  defp merge_paragraph_text(tree, node, processed) do
    case Tree.text(tree, processed) do
      existing when existing in [nil, ""] -> Tree.put_text(tree, processed, Tree.text(tree, node))
      existing -> Tree.put_text(tree, processed, existing <> " " <> (Tree.text(tree, node) || ""))
    end
  end

  defp append_paragraph_child(tree, child, node, processed, options) do
    {tree, newsub} = Tree.create(tree, Tree.tag(tree, child))

    tree =
      if Tree.tag(tree, node) in @p_formatting do
        tree
        |> flatten_formatting(node)
        |> carry_formatting_attrs(child, newsub)
      else
        tree
      end

    tree =
      tree
      |> Tree.put_text(newsub, Tree.text(tree, node))
      |> Tree.put_tail(newsub, Tree.tail(tree, node))

    if Tree.tag(tree, node) == "graphic" do
      case handle_image(tree, node, options) do
        {tree, nil} -> Tree.append(tree, processed, newsub)
        {tree, image} -> Tree.append(tree, processed, image)
      end
    else
      Tree.append(tree, processed, newsub)
    end
  end

  # Nested inline markup inside a hi/ref is flattened into its text, adding the
  # separating space the removed tag boundary used to provide.
  defp flatten_formatting(tree, node) do
    tree
    |> Tree.children(node)
    |> Enum.reduce(tree, fn item, tree ->
      if Tree.exists?(tree, item) do
        item_tag = Tree.tag(tree, item)

        tree
        |> space_before_item(item, item_tag)
        |> Tree.strip_tags(node, [item_tag])
      else
        tree
      end
    end)
  end

  defp space_before_item(tree, item, "lb") do
    case Tree.tail(tree, item) do
      tail when tail in [nil, ""] -> tree
      tail -> Tree.put_tail(tree, item, " " <> String.trim_leading(tail))
    end
  end

  defp space_before_item(tree, item, _tag) do
    text = Tree.text(tree, item)
    if Text.text_chars?(text), do: Tree.put_text(tree, item, " " <> text), else: tree
  end

  defp carry_formatting_attrs(tree, child, newsub) do
    case Tree.tag(tree, child) do
      "hi" ->
        Tree.put_attr(tree, newsub, "rend", Tree.attr(tree, child, "rend", ""))

      "ref" ->
        case Tree.attr(tree, child, "target") do
          nil -> tree
          target -> Tree.put_attr(tree, newsub, "target", target)
        end

      _ ->
        tree
    end
  end

  defp finish_paragraph(tree, processed) do
    kids = Tree.children(tree, processed)

    cond do
      kids != [] ->
        last = List.last(kids)

        tree =
          if Tree.tag(tree, last) == "lb" and Tree.tail(tree, last) == nil,
            do: Tree.delete_element(tree, last),
            else: tree

        {tree, processed}

      Tree.text(tree, processed) not in [nil, ""] ->
        {tree, processed}

      true ->
        {tree, nil}
    end
  end

  # ## Line breaks and leftovers -------------------------------------------

  defp handle_line_break(tree, id, options) do
    if Text.text_chars?(Tree.tail(tree, id)) do
      case HtmlProcessing.process_node(tree, id, options) do
        {tree, nil} ->
          {tree, nil}

        {tree, node} ->
          {tree, paragraph} = Tree.create(tree, "p")
          {Tree.put_text(tree, paragraph, Tree.tail(tree, node)), paragraph}
      end
    else
      {tree, nil}
    end
  end

  defp handle_other_elements(tree, id, potential_tags, options) do
    cond do
      Tree.tag(tree, id) == "div" and String.contains?(Tree.attr(tree, id, "class", ""), "w3-code") ->
        handle_code_blocks(tree, id)

      Tree.tag(tree, id) not in potential_tags ->
        {tree, nil}

      Tree.tag(tree, id) == "div" ->
        promote_div(tree, id, options)

      true ->
        {tree, nil}
    end
  end

  defp promote_div(tree, id, options) do
    case HtmlProcessing.handle_textnode(tree, id, options, comments_fix: false, preserve_spaces: true) do
      {tree, nil} ->
        {tree, nil}

      {tree, node} ->
        if Text.text_chars?(Tree.text(tree, node)) do
          tree = tree |> Tree.clear_attrs(node) |> Tree.put_tag(node, "p")
          {tree, node}
        else
          {tree, nil}
        end
    end
  end

  # ## Images --------------------------------------------------------------

  @doc "Normalizes an image element, resolving its source against the page URL."
  @spec handle_image(Tree.t(), Tree.id() | nil, Options.t() | nil) :: {Tree.t(), Tree.id() | nil}
  def handle_image(tree, nil, _options), do: {tree, nil}

  def handle_image(tree, id, options) do
    {tree, processed} = Tree.create(tree, Tree.tag(tree, id))

    tree =
      case image_source(tree, id) do
        nil -> tree
        src -> Tree.put_attr(tree, processed, "src", src)
      end

    tree =
      tree
      |> copy_attr(id, processed, "alt")
      |> copy_attr(id, processed, "title")

    case Tree.attr(tree, processed, "src") do
      nil ->
        {tree, nil}

      src ->
        tree =
          tree
          |> Tree.put_attr(processed, "src", absolutize_image(src, options))
          |> Tree.put_tail(processed, Tree.tail(tree, id))

        {tree, processed}
    end
  end

  defp image_source(tree, id) do
    direct = Enum.find(["data-src", "src"], &Text.image_file?(Tree.attr(tree, id, &1)))

    if direct do
      Tree.attr(tree, id, direct)
    else
      # lazy-loading themes invent their own data-src-* attributes
      Enum.find_value(Tree.attrs(tree, id), fn {name, value} ->
        if String.starts_with?(name, "data-src") and Text.image_file?(value), do: value
      end)
    end
  end

  defp copy_attr(tree, from, to, name) do
    case Tree.attr(tree, from, name) do
      value when value in [nil, ""] -> tree
      value -> Tree.put_attr(tree, to, name, value)
    end
  end

  defp absolutize_image("http" <> _ = src, _options), do: src

  defp absolutize_image(src, %Options{url: url}) when is_binary(url),
    do: Chushutsu.URL.absolutize(src, Chushutsu.URL.base_url(url) || url)

  defp absolutize_image("//" <> rest, _options), do: "http://" <> rest
  defp absolutize_image(src, _options), do: src

  # ## Tables --------------------------------------------------------------

  @doc "Rewrites an HTML table into `table`/`row`/`cell`, materializing spans."
  @spec handle_table(Tree.t(), Tree.id(), [String.t()], Options.t()) :: {Tree.t(), Tree.id() | nil}
  def handle_table(tree, table_id, potential_tags, options) do
    {tree, newtable} = Tree.create(tree, "table")
    ptags_with_div = Enum.uniq(potential_tags ++ ["div"])

    tree = Tree.strip_tags(tree, table_id, ~w(thead tbody tfoot))

    # Elements inside nested tables are skipped by the cell walk (without being
    # marked done) so the main loop can still handle each nested table itself.
    nested =
      tree
      |> Tree.iterdescendants(table_id, ["table"])
      |> Enum.flat_map(&Tree.iter(tree, &1))
      |> MapSet.new()

    max_cols = count_columns(tree, table_id)
    {tree, newtable} = emit_captions(tree, table_id, newtable, max_cols)

    state = %{
      tree: tree,
      newtable: newtable,
      row: nil,
      rowspans: %{},
      max_cols: max_cols,
      header_emitted: false,
      row_has_th: false,
      nested: nested,
      ptags: ptags_with_div,
      options: options
    }

    state =
      tree
      |> Tree.children(table_id)
      |> Enum.reduce(state, &consume_table_child(&2, &1))

    state = finalize_row(state)

    if Tree.children(state.tree, state.newtable) == [],
      do: {state.tree, nil},
      else: {state.tree, state.newtable}
  end

  # Counted from direct-child rows only, so nested tables do not inflate the width.
  defp count_columns(tree, table_id) do
    tree
    |> Tree.find_children(table_id, "tr")
    |> Enum.map(fn row ->
      tree
      |> Tree.children(row)
      |> Enum.filter(&(Tree.tag(tree, &1) in @table_elems))
      |> Enum.map(&span(tree, &1, "colspan"))
      |> Enum.sum()
    end)
    |> Enum.max(fn -> 0 end)
    |> min(@max_span)
  end

  defp emit_captions(tree, table_id, newtable, max_cols) do
    tree
    |> Tree.find_children(table_id, "caption")
    |> Enum.reduce({tree, newtable}, fn caption, {tree, newtable} ->
      text = tree |> Tree.itertext(caption) |> Enum.join(" ") |> String.trim()

      tree =
        if text == "" do
          tree
        else
          {tree, row} = Tree.create_child(tree, newtable, "row")
          {tree, cell} = new_cell(tree, true)
          tree = tree |> Tree.put_text(cell, text) |> Tree.append(row, cell)
          pad_row(tree, row, max_cols)
        end

      {Tree.put_tag(tree, caption, "done"), newtable}
    end)
  end

  defp consume_table_child(state, elem) do
    case Tree.tag(state.tree, elem) do
      "tr" ->
        state
        |> finalize_row()
        |> start_row()
        |> consume_cells(Tree.children(state.tree, elem))
        |> mark_done(elem)

      tag when tag in @table_elems ->
        # an orphan cell with no <tr> wrapper (malformed HTML)
        state |> consume_cells([elem]) |> mark_done(elem)

      "table" ->
        # left for the main extraction loop to handle on its own
        state

      _other ->
        mark_done(state, elem)
    end
  end

  defp mark_done(state, elem), do: %{state | tree: Tree.put_tag(state.tree, elem, "done")}

  defp start_row(state) do
    {tree, row} = Tree.create(state.tree, "row")
    %{state | tree: tree, row: row, row_has_th: false} |> flush_rowspan_phantoms()
  end

  defp consume_cells(state, cells) do
    Enum.reduce(cells, state, fn cell, state ->
      if Tree.tag(state.tree, cell) in @table_elems,
        do: state |> consume_cell(cell) |> mark_done(cell),
        else: state
    end)
  end

  defp consume_cell(state, cell) do
    state = if state.row, do: state, else: start_row(state)
    header? = Tree.tag(state.tree, cell) == "th" and not state.header_emitted
    state = flush_rowspan_phantoms(%{state | row_has_th: state.row_has_th or header?})

    {tree, new_cell} = new_cell(state.tree, header?)
    colspan = span(tree, cell, "colspan")
    rows = span(tree, cell, "rowspan")

    position = Tree.child_count(tree, state.row)

    # mark the columns this cell spans as occupied for the rows below
    rowspans =
      if rows > 1 do
        Enum.reduce(position..(position + colspan - 1), state.rowspans, &Map.put(&2, &1, rows - 1))
      else
        state.rowspans
      end

    tree = fill_cell(tree, new_cell, cell, state)
    tree = Tree.append(tree, state.row, new_cell)

    # inline colspan padding keeps later rows aligned
    tree =
      Enum.reduce(1..(colspan - 1)//1, tree, fn _i, tree ->
        {tree, filler} = new_cell(tree, header?)
        Tree.append(tree, state.row, filler)
      end)

    %{state | tree: tree, rowspans: rowspans}
  end

  defp fill_cell(tree, new_cell, cell, state) do
    if Tree.children(tree, cell) == [] do
      case HtmlProcessing.process_node(tree, cell, state.options) do
        {tree, nil} ->
          tree

        {tree, node} ->
          tree
          |> Tree.put_text(new_cell, Tree.text(tree, node))
          |> Tree.put_tail(new_cell, Tree.tail(tree, node))
      end
    else
      tree
      |> Tree.put_text(new_cell, Tree.text(tree, cell))
      |> Tree.put_tail(new_cell, Tree.tail(tree, cell))
      # renamed before the inner walk so an orphan span gets wrapped in <p>
      |> Tree.put_tag(cell, "done")
      |> walk_cell_children(cell, new_cell, state)
    end
  end

  defp walk_cell_children(tree, cell, new_cell, state) do
    tree
    |> Tree.iterdescendants(cell)
    |> Enum.reduce(tree, fn child, tree ->
      cond do
        not Tree.exists?(tree, child) or Tree.tag(tree, child) == "done" ->
          tree

        MapSet.member?(state.nested, child) ->
          carry_nested_table_tail(tree, child, new_cell)

        true ->
          tree |> absorb_cell_child(child, new_cell, state) |> Tree.put_tag(child, "done")
      end
    end)
  end

  # Text after a nested </table> still belongs to the enclosing cell.
  defp carry_nested_table_tail(tree, child, new_cell) do
    tail = Tree.tail(tree, child)

    if Tree.tag(tree, child) == "table" and tail not in [nil, ""] do
      case List.last(Tree.children(tree, new_cell)) do
        nil -> Tree.put_text(tree, new_cell, (Tree.text(tree, new_cell) || "") <> tail)
        last -> Tree.put_tail(tree, last, (Tree.tail(tree, last) || "") <> tail)
      end
    else
      tree
    end
  end

  defp absorb_cell_child(tree, child, new_cell, state) do
    tag = Tree.tag(tree, child)

    cond do
      tag in @table_elems ->
        tree = Tree.put_tag(tree, child, "cell")

        case HtmlProcessing.handle_textnode(tree, child, state.options, preserve_spaces: true) do
          {tree, nil} -> tree
          {tree, node} -> define_newelem(tree, node, new_cell, keep_children: true) |> elem(0)
        end

      tag in @inline_wrap_tags ->
        absorb_inline_cell_child(tree, child, new_cell, state)

      # lists inside cells are noise except in recall mode (measured precision loss)
      tag == "list" and state.options.focus == :recall ->
        case handle_lists(tree, child, state.options) do
          {tree, nil} -> tree
          {tree, list} -> Tree.append(tree, new_cell, list)
        end

      true ->
        case handle_textelem(tree, child, state.ptags, state.options) do
          {tree, nil} -> tree
          {tree, node} -> define_newelem(tree, node, new_cell, keep_children: true) |> elem(0)
        end
    end
  end

  defp absorb_inline_cell_child(tree, child, new_cell, state) do
    case HtmlProcessing.handle_textnode(tree, child, state.options, preserve_spaces: true) do
      {tree, nil} ->
        # handle_textnode drops an inline wrapper with children but no direct text
        # (e.g. <ref><hi>link text</hi></ref>); carry the subtree over instead
        if Tree.children(tree, child) != [] do
          {tree, _} = define_newelem(tree, child, new_cell, keep_children: true)
          Tree.put_tag_all(tree, Tree.iter(tree, child), "done")
        else
          tree
        end

      {tree, node} ->
        define_newelem(tree, node, new_cell, keep_children: true) |> elem(0)
    end
  end

  defp new_cell(tree, header?) do
    attrs = if header?, do: [{"role", "head"}], else: []
    Tree.create(tree, "cell", attrs)
  end

  defp span(tree, id, attr) do
    value = Tree.attr(tree, id, attr, "1")

    # isdecimal, not isdigit: superscripts are digits but not parseable numbers
    if Regex.match?(~r/^\d+$/, value),
      do: min(String.to_integer(value), @max_span),
      else: 1
  end

  defp flush_rowspan_phantoms(%{row: nil} = state), do: state

  defp flush_rowspan_phantoms(state) do
    column = Tree.child_count(state.tree, state.row)

    case Map.fetch(state.rowspans, column) do
      :error ->
        state

      {:ok, remaining} ->
        {tree, filler} = new_cell(state.tree, false)
        tree = Tree.append(tree, state.row, filler)

        rowspans =
          if remaining - 1 == 0,
            do: Map.delete(state.rowspans, column),
            else: Map.put(state.rowspans, column, remaining - 1)

        flush_rowspan_phantoms(%{state | tree: tree, rowspans: rowspans})
    end
  end

  defp finalize_row(%{row: nil} = state), do: state

  defp finalize_row(state) do
    if Tree.child_count(state.tree, state.row) == 0 do
      %{state | row: nil}
    else
      state = flush_rowspan_phantoms(state)
      tree = pad_row(state.tree, state.row, state.max_cols)

      tree =
        if row_has_content?(tree, state.row),
          do: Tree.append(tree, state.newtable, state.row),
          else: tree

      %{state | tree: tree, row: nil, header_emitted: state.header_emitted or state.row_has_th}
    end
  end

  defp pad_row(tree, row, max_cols) do
    if Tree.child_count(tree, row) < max_cols do
      {tree, filler} = new_cell(tree, false)
      tree |> Tree.append(row, filler) |> pad_row(row, max_cols)
    else
      tree
    end
  end

  defp row_has_content?(tree, row) do
    tree
    |> Tree.children(row)
    |> Enum.any?(&(Tree.text(tree, &1) not in [nil, ""] or Tree.children(tree, &1) != []))
  end

  # ## Shared helpers ------------------------------------------------------

  # Creates a fresh sub-element mirroring `source`, keeping only the internal
  # attributes and — when asked — its inline children.
  defp define_newelem(tree, source, target, opts \\ [])
  defp define_newelem(tree, nil, _target, _opts), do: {tree, nil}

  defp define_newelem(tree, source, target, opts) do
    {tree, child} = Tree.create_child(tree, target, Tree.tag(tree, source))

    tree =
      tree
      |> Tree.put_text(child, Tree.text(tree, source))
      |> Tree.put_tail(child, Tree.tail(tree, source))
      |> copy_kept_attrs(source, child)

    if Keyword.get(opts, :keep_children, false) do
      {carry_inline_children(tree, source, child), child}
    else
      {tree, child}
    end
  end

  defp copy_kept_attrs(tree, source, target) do
    tree
    |> Tree.attrs(source)
    |> Enum.filter(fn {name, _value} -> name in @keep_attrs end)
    |> Enum.reduce(tree, fn {name, value}, tree -> Tree.put_attr(tree, target, name, value) end)
  end

  defp carry_inline_children(tree, source, target) do
    carried = @inline_carried ++ ["lb"]

    tree
    |> Tree.children(source)
    |> Enum.filter(&(Tree.tag(tree, &1) in carried))
    |> Enum.reduce(tree, fn sub, tree ->
      {tree, _} = define_newelem(tree, sub, target, keep_children: true)
      # only the carried subtree is marked done; non-carried siblings stay processable
      Tree.put_tag_all(tree, Tree.iter(tree, sub), "done")
    end)
  end

  # A formatting element whose children must be carried verbatim.
  defp wraps_inline?(tree, id) do
    Tree.children(tree, id) != [] and
      (Tree.tag(tree, id) == "ref" or
         Enum.any?(Tree.children(tree, id), &(Tree.tag(tree, &1) in @inline_carried)))
  end

  defp copy_rendition(tree, from, to) do
    case Tree.attr(tree, from, "rend") do
      nil -> tree
      rend -> Tree.put_attr(tree, to, "rend", rend)
    end
  end

  defp text_element?(tree, id),
    do: id != nil and Text.text_chars?(Enum.join(Tree.itertext(tree, id)))

  @doc """
  Plain concatenation of an element's text, for the recovery and repeat checks.

  Deliberately *not* space-joined: inline tag boundaries must stay closed, so
  `Hyper<b>link</b>ed` compares as `Hyperlinked`. Both sides of every such
  comparison use this, or invented spaces would defeat it.
  """
  @spec elem_text(Tree.t(), Tree.id()) :: String.t()
  def elem_text(tree, id), do: tree |> Tree.itertext(id) |> Enum.join() |> Text.trim()

  defp body_text(tree, body), do: tree |> Tree.itertext(body) |> Enum.join(" ") |> String.trim()
end
