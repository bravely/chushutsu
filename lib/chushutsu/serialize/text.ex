defmodule Chushutsu.Serialize.Text do
  @moduledoc """
  Renders an extracted body as plain text or Markdown.

  One recursive walk emits string fragments that are concatenated at the end.
  Whether a fragment gets a newline, a space or nothing depends on where it sits
  — inside a table cell, inside a list item, or at block level — so those two
  flags are threaded down the recursion instead of being re-derived by walking
  ancestors at every node.
  """

  alias Chushutsu.{Settings, Text, Tree}

  @heading_levels ~w(1 2 3 4 5 6)

  # Resolved at compile time. These are consulted once per element in the render
  # walk, and calling the Settings functions there rebuilt the lists every time,
  # which also forced `in` to compile down to `lists:member/2`.
  @inline_formattable Settings.inline_formattable()
  @inline_consuming Settings.inline_consuming()
  @newline_elems Settings.newline_elems()
  @special_formatting Settings.special_formatting()
  @hi_formatting Settings.hi_formatting()

  # Characters that already separate content, so no extra space is needed.
  @separators [" ", "\n", "|", ""]

  # Block and inline LaTeX math; only matched pairs are converted.
  @math_block ~r/(?<!\S)\\\[(.+?)\\\]/s
  @math_inline ~r/\\\((.+?)\\\)/s

  @doc """
  Renders a body element.

  With `include_formatting: true` the output is Markdown — headings, emphasis,
  links, fenced code and GFM tables; otherwise it is plain text.
  """
  @spec render(Tree.t(), Tree.id() | nil, boolean) :: String.t()
  def render(_tree, nil, _include_formatting), do: ""

  def render(tree, id, include_formatting) do
    {tree, id} =
      if include_formatting do
        # math rewriting and emphasis collapsing mutate the tree; work on a copy
        {tree, copy} = Tree.deep_copy(tree, id)
        {tree |> convert_math_tree(copy) |> collapse_emphasis(copy, MapSet.new()), copy}
      else
        {tree, id}
      end

    tree
    |> process_element(id, [], include_formatting, false, false)
    |> Enum.reverse()
    |> IO.iodata_to_binary()
    |> Text.sanitize(preserve_space: true)
    |> Kernel.||("")
    |> Text.unescape()
  end

  # ## The walk ------------------------------------------------------------

  defp process_element(tree, id, acc, formatting?, in_cell, in_item) do
    tag = Tree.tag(tree, id)
    in_cell = in_cell or tag == "cell"
    in_item = in_item or tag == "item"

    acc = open_cell(tree, id, tag, acc)
    acc = block_leading_newline(tag, acc, in_cell, in_item)

    consumes_children = consumes_inline_children?(tree, id)
    renders_inline = Tree.text(tree, id) not in [nil, ""] or consumes_children

    acc = emit_own_text(tree, id, tag, acc, formatting?, in_cell, in_item, renders_inline, consumes_children)
    acc = emit_cell_tail(tree, id, tag, acc, in_cell)
    acc = sublist_newline(tag, acc, in_item)

    acc =
      if consumes_children do
        acc
      else
        Enum.reduce(Tree.children(tree, id), acc, &process_element(tree, &1, &2, formatting?, in_cell, in_item))
      end

    case close_element(tree, id, tag, acc, formatting?, in_cell, in_item, renders_inline) do
      {:halt, acc} -> acc
      {:cont, acc} -> emit_trailing(tree, id, tag, acc, formatting?, in_cell, in_item)
    end
  end

  defp open_cell(tree, id, "cell", acc) do
    if Tree.prev_sibling(tree, id) == nil, do: ["| " | acc], else: acc
  end

  defp open_cell(_tree, _id, _tag, acc), do: acc

  # A block element starts on its own line rather than being mashed onto
  # whatever loose text preceded it.
  defp block_leading_newline(tag, acc, in_cell, in_item) do
    if tag in @newline_elems and not in_cell and not in_item and
         last_char(acc) not in @separators,
       do: ["\n" | acc],
       else: acc
  end

  defp emit_own_text(tree, id, _tag, acc, formatting?, in_cell, in_item, true, _consumes) do
    [replace_element_text(tree, id, formatting?, in_item, in_cell) | acc]
  end

  defp emit_own_text(tree, id, tag, acc, formatting?, in_cell, _in_item, false, _consumes) do
    # a heading that starts with an inline child still needs its # prefix
    if formatting? and tag == "head" and not in_cell and Tree.children(tree, id) != [],
      do: ["#{heading_prefix(tree, id)} " | acc],
      else: acc
  end

  defp emit_cell_tail(tree, id, tag, acc, true) when tag != "graphic" do
    case Tree.tail(tree, id) do
      nil ->
        acc

      tail ->
        tail = String.trim(tail)

        tail =
          if tail != "" and last_char(acc) not in [" ", "|", ""], do: " " <> tail, else: tail

        [escape_cell(tail) | acc]
    end
  end

  defp emit_cell_tail(_tree, _id, _tag, acc, _in_cell), do: acc

  # A sublist starts on its own line rather than on the parent item's.
  defp sublist_newline("list", acc, true) do
    if last_char(acc) not in ["\n", ""], do: ["\n" | acc], else: acc
  end

  defp sublist_newline(_tag, acc, _in_item), do: acc

  defp close_element(tree, id, tag, acc, formatting?, in_cell, in_item, false) do
    cond do
      tag == "graphic" ->
        {:cont, emit_image(tree, id, acc, formatting?, in_cell, in_item)}

      tag in @newline_elems ->
        {:cont, emit_empty_block(tree, id, tag, acc, in_cell)}

      tag not in ["cell", "item"] ->
        # cells and items still need their closing separator
        {:halt, acc}

      true ->
        {:cont, acc}
    end
  end

  defp close_element(_tree, _id, _tag, acc, _formatting?, _in_cell, _in_item, true), do: {:cont, acc}

  defp emit_image(tree, id, acc, formatting?, in_cell, in_item) do
    image = list_marker(tree, id, in_item, formatting?) <> image_markup(tree, id)
    acc = [if(in_cell, do: escape_cell(image), else: image) | acc]

    case Tree.tail(tree, id) do
      nil -> acc
      tail -> [if(in_cell, do: escape_cell(" " <> String.trim(tail)), else: " " <> String.trim(tail)) | acc]
    end
  end

  defp emit_empty_block(tree, id, "row", acc, _in_cell) do
    cells = Tree.find_children(tree, id, "cell")

    # rows are padded to full width upstream, so the separator matches the header
    if Enum.any?(cells, &(Tree.attr(tree, &1, "role") == "head")),
      do: ["\n|#{String.duplicate("---|", length(cells))}\n" | acc],
      else: acc
  end

  defp emit_empty_block(_tree, _id, _tag, acc, in_cell) do
    # a block inside a cell must not inject a row-breaking newline
    if in_cell, do: acc, else: ["\n" | acc]
  end

  defp emit_trailing(tree, id, tag, acc, formatting?, in_cell, in_item) do
    last_in_item = in_item and last_element_in_item?(tree, id)

    acc = separator(tree, id, tag, acc, formatting?, in_cell, in_item, last_in_item)
    acc = emit_tail(tree, id, tag, acc, in_cell, in_item)

    if last_in_item and not in_cell, do: ["\n" | acc], else: acc
  end

  defp separator(tree, id, tag, acc, formatting?, in_cell, in_item, last_in_item) do
    cond do
      tag in @newline_elems and not in_cell and not in_item ->
        [if(formatting? and tag != "row", do: "\n␤\n", else: "\n") | acc]

      tag == "cell" ->
        [" | " | acc]

      tag in ["head", "item"] and in_cell and not last_element_in_cell?(tree, id) ->
        # separate flattened blocks inside a cell instead of mashing them
        [" " | acc]

      tag not in @special_formatting and not last_in_item and
          not last_element_in_cell?(tree, id) ->
        [" " | acc]

      true ->
        acc
    end
  end

  defp emit_tail(tree, id, tag, acc, in_cell, in_item) do
    tail = Tree.tail(tree, id)

    if tail != nil and not in_cell and tag != "graphic" do
      tail = if in_item or tag == "list", do: String.trim(tail), else: tail

      # restore a separator lost during extraction, so **bold** does not run
      # straight into the word after it
      tail =
        if tail != "" and in_item and last_char(acc) not in @separators, do: " " <> tail, else: tail

      [tail | acc]
    else
      acc
    end
  end

  # ## Element text --------------------------------------------------------

  @doc false
  def replace_element_text(tree, id, formatting?, in_item, in_cell) do
    tag = Tree.tag(tree, id)

    text =
      if consumes_inline_children?(tree, id),
        do: collect_inline_text(tree, id, formatting?),
        else: Tree.text(tree, id) || ""

    text
    |> apply_formatting(tree, id, tag, formatting?, in_cell)
    |> apply_link(tree, id)
    |> apply_cell(tree, id)
    |> prepend_list_marker(tree, id, in_item, formatting?)
    |> maybe_escape_cell(in_cell)
  end

  defp apply_formatting(text, _tree, _id, _tag, false, _in_cell), do: text
  defp apply_formatting("", _tree, _id, _tag, true, _in_cell), do: ""

  defp apply_formatting(text, tree, id, tag, true, in_cell) do
    case tag do
      t when t in ["article", "list", "table"] -> String.trim(text)
      "head" when not in_cell -> "#{heading_prefix(tree, id)} #{text}"
      "del" -> md_wrap(String.replace(text, "~~", "~\\~"), "~~")
      "hi" -> apply_emphasis(text, Tree.attr(tree, id, "rend"))
      "code" -> apply_code(text, tree, id)
      _ -> text
    end
  end

  defp apply_emphasis(text, rend) do
    case Map.get(@hi_formatting, rend || "") do
      nil -> text
      "`" -> md_code(text)
      marker -> md_wrap(text, marker)
    end
  end

  defp apply_code(text, tree, id) do
    breaks = Tree.find_all(tree, id, "lb")

    if String.contains?(text, "\n") or breaks != [] do
      text = Enum.reduce(breaks, text, &(&2 <> "\n" <> (Tree.tail(tree, &1) || "")))
      fence = code_fence(text, 3)
      "#{fence}\n#{text}\n#{fence}\n"
    else
      md_code(text)
    end
  end

  defp apply_link(text, tree, id) do
    if Tree.tag(tree, id) == "ref" do
      case String.trim(text) do
        "" -> text
        stripped -> String.replace(text, stripped, md_link(stripped, Tree.attr(tree, id, "target")), global: false)
      end
    else
      text
    end
  end

  defp apply_cell(text, tree, id) do
    if Tree.tag(tree, id) == "cell" do
      text = String.trim(text)
      # keep the cell's own text apart from its children
      if text != "" and Tree.children(tree, id) != [], do: text <> " ", else: text
    else
      text
    end
  end

  defp prepend_list_marker(text, tree, id, in_item, formatting?),
    do: list_marker(tree, id, in_item, formatting?) <> text

  defp maybe_escape_cell(text, true), do: escape_cell(text)
  defp maybe_escape_cell(text, false), do: text

  # Text from the element plus its inline children, which are rendered in place
  # rather than recursed into.
  defp collect_inline_text(tree, id, formatting?) do
    initial = if Tree.text(tree, id) not in [nil, ""], do: [Tree.text(tree, id)], else: []

    tree
    |> Tree.children(id)
    |> Enum.reduce(initial, fn child, parts ->
      parts =
        case Tree.tag(tree, child) do
          "graphic" -> [image_markup(tree, child) | parts]
          "lb" -> ["\n" | parts]
          tag when tag in @inline_formattable -> [replace_element_text(tree, child, formatting?, nil, false) | parts]
          _ -> if Tree.text(tree, child), do: [Tree.text(tree, child) | parts], else: parts
        end

      if Tree.tail(tree, child), do: [Tree.tail(tree, child) | parts], else: parts
    end)
    |> Enum.reverse()
    |> IO.iodata_to_binary()
  end

  defp consumes_inline_children?(tree, id),
    do: Tree.tag(tree, id) in @inline_consuming and Tree.children(tree, id) != []

  # ## Markdown pieces -----------------------------------------------------

  defp heading_prefix(tree, id) do
    level = Tree.attr(tree, id, "rend") || ""
    number = if String.slice(level, 1, 1) in @heading_levels, do: String.slice(level, 1, 1), else: "2"
    String.duplicate("#", String.to_integer(number))
  end

  defp image_markup(tree, id) do
    alt = "#{Tree.attr(tree, id, "title", "")} #{Tree.attr(tree, id, "alt", "")}" |> String.trim()
    md_link(alt, Tree.attr(tree, id, "src", ""), image: true)
  end

  defp md_link(text, url, opts \\ [])

  defp md_link(text, url, opts) do
    escaped = text |> String.replace("[", "\\[") |> String.replace("]", "\\]")
    prefix = if Keyword.get(opts, :image, false), do: "!", else: ""

    case url do
      nil ->
        "#{prefix}[#{escaped}]"

      url ->
        "#{prefix}[#{escaped}](#{safe_destination(url)})"
    end
  end

  # A destination containing spaces or brackets needs angle brackets, and the
  # brackets themselves must then be escaped or they truncate the target.
  defp safe_destination(url) do
    if String.contains?(url, [" ", "<", ">", "(", ")"]) do
      inner =
        url
        |> String.replace("\\", "\\\\")
        |> String.replace("<", "\\<")
        |> String.replace(">", "\\>")

      "<#{inner}>"
    else
      url
    end
  end

  # Wraps text in a marker, leaving flanking whitespace outside it so the
  # emphasis stays valid CommonMark.
  defp md_wrap(text, marker) do
    case String.trim(text) do
      "" -> text
      stripped -> String.replace(text, stripped, "#{marker}#{stripped}#{marker}", global: false)
    end
  end

  defp md_code(text) do
    case String.trim(text) do
      "" -> text
      stripped -> String.replace(text, stripped, code_span(stripped), global: false)
    end
  end

  defp code_span(text) do
    fence = code_fence(text, 1)
    # CommonMark: a space stops an edge backtick from merging with the fence
    text = if String.starts_with?(text, "`") or String.ends_with?(text, "`"), do: " #{text} ", else: text
    "#{fence}#{text}#{fence}"
  end

  # The shortest backtick run that does not occur inside the text.
  defp code_fence(text, min_length) do
    text
    |> String.graphemes()
    |> Enum.reduce({min_length, 0}, fn
      "`", {fence, run} -> {max(fence, run + 2), run + 1}
      _other, {fence, _run} -> {fence, 0}
    end)
    |> elem(0)
    |> then(&String.duplicate("`", &1))
  end

  defp escape_cell(text), do: text |> String.replace("|", "\\|") |> String.replace("\n", " ")

  # ## List markers --------------------------------------------------------

  # The marker for the first element of a list item; empty everywhere else.
  defp list_marker(tree, id, in_item, formatting?) do
    in_item = if is_nil(in_item), do: element_in_item?(tree, id), else: in_item

    with true <- in_item,
         item when not is_nil(item) <- item_if_first_element(tree, id),
         false <- in_table_cell?(tree, id) do
      # a stray <item> with no enclosing <list> reports depth 0, so clamp
      indent = String.duplicate("  ", max(ordered_depth(tree, item) - 1, 0))
      parent = Tree.parent(tree, item)

      # numbering is markdown-only; in plain text it injects bare digit tokens
      if (formatting? and parent) && Tree.attr(tree, parent, "rend") == "ol" do
        "#{indent}#{preceding_items(tree, item) + 1}. "
      else
        "#{indent}- "
      end
    else
      _ -> ""
    end
  end

  defp ordered_depth(tree, item),
    do: tree |> Tree.ancestors(item) |> Enum.count(&(Tree.tag(tree, &1) == "list"))

  defp preceding_items(tree, item),
    do: tree |> Tree.prev_siblings(item) |> Enum.count(&(Tree.tag(tree, &1) == "item"))

  defp element_in_item?(tree, id), do: Tree.tag(tree, id) == "item" or Tree.has_ancestor?(tree, id, ["item"])

  defp in_table_cell?(tree, id), do: Tree.tag(tree, id) == "cell" or Tree.has_ancestor?(tree, id, ["cell"])

  # The enclosing item when `id` carries its first content, else nil.
  defp item_if_first_element(tree, id) do
    if Tree.tag(tree, id) == "item" do
      if Tree.text(tree, id) not in [nil, ""], do: id, else: nil
    else
      item = tree |> Tree.ancestors(id) |> Enum.find(&(Tree.tag(tree, &1) == "item"))

      if (item && Tree.text(tree, item) in [nil, ""]) and
           List.first(Tree.iterdescendants(tree, item)) == id,
         do: item,
         else: nil
    end
  end

  defp last_element_in_item?(tree, id) do
    cond do
      not element_in_item?(tree, id) -> false
      Tree.tag(tree, id) == "item" -> Tree.children(tree, id) == []
      true -> next_is_item_boundary?(tree, id)
    end
  end

  defp next_is_item_boundary?(tree, id) do
    case Tree.next_sibling(tree, id) do
      nil -> true
      next -> Tree.tag(tree, next) == "item"
    end
  end

  defp last_element_in_cell?(tree, id) do
    if in_table_cell?(tree, id) do
      container = if Tree.tag(tree, id) == "cell", do: id, else: Tree.parent(tree, id)
      Tree.children(tree, container) == [] or List.last(Tree.children(tree, container)) == id
    else
      false
    end
  end

  # ## Tree rewrites for markdown ------------------------------------------

  # Splices out redundant emphasis levels in linear `hi` chains, so nested <font>
  # junk renders as ***X*** rather than a wall of asterisks.
  defp collapse_emphasis(tree, id, active) do
    {tree, active} =
      if Tree.tag(tree, id) == "hi" do
        here = Map.get(@hi_formatting, Tree.attr(tree, id, "rend") || "")
        active = if here, do: MapSet.put(active, here), else: active
        {absorb_nested_emphasis(tree, id, active), active}
      else
        {tree, active}
      end

    Enum.reduce(Tree.children(tree, id), tree, &collapse_emphasis(&2, &1, active))
  end

  defp absorb_nested_emphasis(tree, id, active) do
    with [child] <- Tree.children(tree, id),
         true <- Text.trim(Tree.text(tree, id)) == "",
         true <- Tree.tag(tree, child) == "hi",
         true <- Text.trim(Tree.tail(tree, child)) == "",
         true <- Map.get(@hi_formatting, Tree.attr(tree, child, "rend") || "") in active do
      tree =
        tree
        |> Tree.put_text(id, (Tree.text(tree, id) || "") <> (Tree.text(tree, child) || ""))
        |> Tree.extend(id, Tree.children(tree, child))
        |> Tree.delete_element(child, keep_tail: false)

      absorb_nested_emphasis(tree, id, active)
    else
      _ -> tree
    end
  end

  defp convert_math_tree(tree, id) do
    # code content is verbatim, so its whole subtree is skipped
    if Tree.tag(tree, id) == "code" or
         (Tree.tag(tree, id) == "hi" and
            Map.get(@hi_formatting, Tree.attr(tree, id, "rend") || "") == "`") do
      tree
    else
      tree = if Tree.text(tree, id), do: Tree.put_text(tree, id, convert_math(Tree.text(tree, id))), else: tree

      Enum.reduce(Tree.children(tree, id), tree, fn child, tree ->
        tree = convert_math_tree(tree, child)
        # a code element's tail is prose, so it is still converted
        if Tree.tail(tree, child),
          do: Tree.put_tail(tree, child, convert_math(Tree.tail(tree, child))),
          else: tree
      end)
    end
  end

  defp convert_math(text) do
    text
    |> then(&Regex.replace(@math_block, &1, fn _match, inner -> "\n$$\n#{String.trim(inner)}\n$$\n" end))
    |> then(&Regex.replace(@math_inline, &1, fn _match, inner -> "$#{inner}$" end))
  end

  # ## Misc ----------------------------------------------------------------

  defp last_char([]), do: ""

  defp last_char([head | rest]) do
    case String.last(IO.iodata_to_binary([head])) do
      nil -> last_char(rest)
      char -> char
    end
  end
end
