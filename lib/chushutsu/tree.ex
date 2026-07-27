defmodule Chushutsu.Tree do
  @moduledoc """
  A mutable-feeling but purely functional document tree with `lxml` semantics.

  Trafilatura's extractor is written against `lxml`, so the port needs the same
  primitives: every element carries `text` (the characters before its first child)
  *and* `tail` (the characters between its own closing tag and the next sibling),
  elements know their parent, and the algorithm rewires nodes in place while it
  walks them.

  Rather than model that with nested structs — where every deep update means
  rebuilding a path, and `parent` is unrepresentable — nodes live in a flat arena
  keyed by integer id. Every operation takes the tree and returns a new one, so
  the structure stays immutable and easy to test, while parent lookups, sibling
  lookups and rewiring all stay cheap.

  Ids are stable: an id obtained before a mutation still refers to the same node
  afterwards, which is what lets the extractor collect a list of elements and then
  mutate them one by one.
  """

  alias Chushutsu.Tree.Node

  defstruct nodes: %{}, root: nil, counter: 0

  @type id :: pos_integer()
  @type t :: %__MODULE__{nodes: %{id => Node.t()}, root: id | nil, counter: non_neg_integer()}

  defmodule Node do
    @moduledoc false
    defstruct [:id, :tag, :parent, attrs: [], text: nil, tail: nil, children: []]

    @type t :: %__MODULE__{
            id: Chushutsu.Tree.id(),
            tag: String.t(),
            parent: Chushutsu.Tree.id() | nil,
            attrs: [{String.t(), String.t()}],
            text: String.t() | nil,
            tail: String.t() | nil,
            children: [Chushutsu.Tree.id()]
          }
  end

  # Void elements never get a closing tag when serialized back to HTML.
  @void_tags ~w(area base br col embed hr img input link meta param source track wbr)

  @doc "An empty tree with no root."
  @spec new() :: t
  def new, do: %__MODULE__{}

  # ## Node creation -------------------------------------------------------

  @doc """
  Mints a detached element and returns it with the updated tree.

  Detached elements are ordinary arena members: they can be filled in, then
  `append/3`ed somewhere, or discarded by simply never linking them.
  """
  @spec create(t, String.t(), [{String.t(), String.t()}]) :: {t, id}
  def create(%__MODULE__{} = tree, tag, attrs \\ []) do
    id = tree.counter + 1
    node = %Node{id: id, tag: tag, attrs: attrs}
    {%{tree | nodes: Map.put(tree.nodes, id, node), counter: id}, id}
  end

  @doc "Creates an element and appends it to `parent` in one step (lxml's `SubElement`)."
  @spec create_child(t, id, String.t(), [{String.t(), String.t()}]) :: {t, id}
  def create_child(tree, parent, tag, attrs \\ []) do
    {tree, id} = create(tree, tag, attrs)
    {append(tree, parent, id), id}
  end

  # ## Accessors -----------------------------------------------------------

  @doc "The document root, or `nil` for an empty tree."
  @spec root(t) :: id | nil
  def root(%__MODULE__{root: root}), do: root

  @doc "Every id in the arena, including detached subtrees. Mostly useful in tests."
  @spec all_ids(t) :: [id]
  def all_ids(%__MODULE__{nodes: nodes}), do: Map.keys(nodes)

  @doc "Whether `id` still refers to a live node."
  @spec exists?(t, id | nil) :: boolean
  def exists?(_tree, nil), do: false
  def exists?(%__MODULE__{nodes: nodes}, id), do: :erlang.is_map_key(id, nodes)

  @spec node(t, id) :: Node.t() | nil
  def node(%__MODULE__{nodes: nodes}, id), do: Map.get(nodes, id)

  # These run in the tens of millions per corpus pass, so each is a single
  # pattern-matched map lookup rather than a call through node/2.

  @spec tag(t, id) :: String.t() | nil
  def tag(%__MODULE__{nodes: nodes}, id) do
    case nodes do
      %{^id => %Node{tag: tag}} -> tag
      _ -> nil
    end
  end

  @spec text(t, id) :: String.t() | nil
  def text(%__MODULE__{nodes: nodes}, id) do
    case nodes do
      %{^id => %Node{text: text}} -> text
      _ -> nil
    end
  end

  @spec tail(t, id) :: String.t() | nil
  def tail(%__MODULE__{nodes: nodes}, id) do
    case nodes do
      %{^id => %Node{tail: tail}} -> tail
      _ -> nil
    end
  end

  @spec attrs(t, id) :: [{String.t(), String.t()}]
  def attrs(%__MODULE__{nodes: nodes}, id) do
    case nodes do
      %{^id => %Node{attrs: attrs}} -> attrs
      _ -> []
    end
  end

  @spec children(t, id) :: [id]
  def children(%__MODULE__{nodes: nodes}, id) do
    case nodes do
      %{^id => %Node{children: children}} -> children
      _ -> []
    end
  end

  @spec parent(t, id) :: id | nil
  def parent(%__MODULE__{nodes: nodes}, id) do
    case nodes do
      %{^id => %Node{parent: parent}} -> parent
      _ -> nil
    end
  end

  @doc "Number of direct children, matching lxml's `len(element)`."
  @spec child_count(t, id) :: non_neg_integer
  def child_count(tree, id), do: length(children(tree, id))

  @doc "Attribute lookup with an optional default."
  @spec attr(t, id, String.t(), String.t() | nil) :: String.t() | nil
  def attr(tree, id, key, default \\ nil) do
    case List.keyfind(attrs(tree, id), key, 0) do
      {^key, value} -> value
      nil -> default
    end
  end

  @doc """
  The value of whichever of `keys` appears first *in source order*.

  XPath's `@id|@class` builds a node-set and `re:test` coerces it with
  `string()`, which takes only the first node in document order — that is, the
  attribute written first on the tag, not the first one listed in the
  expression. Several of trafilatura's discard rules depend on exactly this
  quirk, so it is reproduced rather than smoothed over.
  """
  @spec first_attr(t, id, [String.t()]) :: String.t() | nil
  def first_attr(tree, id, keys) do
    Enum.find_value(attrs(tree, id), fn {key, value} -> if key in keys, do: value end)
  end

  # ## Attribute and text mutation -----------------------------------------

  @spec put_text(t, id, String.t() | nil) :: t
  def put_text(tree, id, text), do: update_node(tree, id, &%{&1 | text: text})

  @spec put_tail(t, id, String.t() | nil) :: t
  def put_tail(tree, id, tail), do: update_node(tree, id, &%{&1 | tail: tail})

  @spec put_tag(t, id, String.t()) :: t
  def put_tag(tree, id, tag), do: update_node(tree, id, &%{&1 | tag: tag})

  @doc "Sets `tag` on every id in the list."
  @spec put_tag_all(t, [id], String.t()) :: t
  def put_tag_all(tree, ids, tag), do: Enum.reduce(ids, tree, &put_tag(&2, &1, tag))

  @doc "Sets an attribute, preserving its position when it already exists."
  @spec put_attr(t, id, String.t(), String.t()) :: t
  def put_attr(tree, id, key, value) do
    update_node(tree, id, fn node ->
      attrs =
        if List.keymember?(node.attrs, key, 0),
          do: List.keyreplace(node.attrs, key, 0, {key, value}),
          else: node.attrs ++ [{key, value}]

      %{node | attrs: attrs}
    end)
  end

  @spec delete_attr(t, id, String.t()) :: t
  def delete_attr(tree, id, key),
    do: update_node(tree, id, &%{&1 | attrs: List.keydelete(&1.attrs, key, 0)})

  @spec clear_attrs(t, id) :: t
  def clear_attrs(tree, id), do: update_node(tree, id, &%{&1 | attrs: []})

  @spec put_attrs(t, id, [{String.t(), String.t()}]) :: t
  def put_attrs(tree, id, attrs), do: update_node(tree, id, &%{&1 | attrs: attrs})

  defp update_node(%__MODULE__{} = tree, id, fun) do
    case tree.nodes do
      %{^id => node} -> %{tree | nodes: Map.put(tree.nodes, id, fun.(node))}
      _ -> tree
    end
  end

  # ## Structure -----------------------------------------------------------

  @doc "Appends `child` as the last child of `parent`, detaching it from any old parent."
  @spec append(t, id, id) :: t
  def append(tree, parent, child) do
    tree = detach(tree, child)

    tree
    |> update_node(parent, &%{&1 | children: &1.children ++ [child]})
    |> update_node(child, &%{&1 | parent: parent})
  end

  @doc "Appends several children in order."
  @spec extend(t, id, [id]) :: t
  def extend(tree, parent, children), do: Enum.reduce(children, tree, &append(&2, parent, &1))

  @doc "Inserts `child` at `position` among `parent`'s children."
  @spec insert(t, id, non_neg_integer, id) :: t
  def insert(tree, parent, position, child) do
    tree = detach(tree, child)

    tree
    |> update_node(parent, &%{&1 | children: List.insert_at(&1.children, position, child)})
    |> update_node(child, &%{&1 | parent: parent})
  end

  @doc "Inserts `sibling` directly after `reference` (lxml's `addnext`)."
  @spec insert_after(t, id, id) :: t
  def insert_after(tree, reference, sibling) do
    case parent(tree, reference) do
      nil -> tree
      parent -> insert(tree, parent, index_in_parent(tree, reference) + 1, sibling)
    end
  end

  @doc "Unlinks a node from its parent without touching the node itself."
  @spec detach(t, id) :: t
  def detach(tree, id) do
    case parent(tree, id) do
      nil ->
        tree

      parent ->
        tree
        |> update_node(parent, &%{&1 | children: List.delete(&1.children, id)})
        |> update_node(id, &%{&1 | parent: nil})
    end
  end

  @doc """
  Removes an element from the tree, mirroring `lxml.html`'s `delete_element`.

  By default the element's tail is preserved: it belongs to the surrounding
  prose, not to the element, so it is joined onto the previous sibling's tail or
  onto the parent's text. Pass `keep_tail: false` to drop it along with the
  element — the extractor does that when the whole region is boilerplate.
  """
  @spec delete_element(t, id, keyword) :: t
  def delete_element(tree, id), do: do_delete_element(tree, id, true)

  def delete_element(tree, id, opts), do: do_delete_element(tree, id, Keyword.get(opts, :keep_tail, true))

  defp do_delete_element(tree, id, keep_tail) do
    case parent(tree, id) do
      nil ->
        tree

      parent ->
        tree
        |> maybe_reattach_tail(id, parent, keep_tail)
        |> drop_subtree(id)
    end
  end

  defp maybe_reattach_tail(tree, id, parent, keep_tail) do
    tail = tail(tree, id)

    if keep_tail and tail not in [nil, ""] do
      case prev_sibling(tree, id) do
        nil -> put_text(tree, parent, (text(tree, parent) || "") <> tail)
        previous -> put_tail(tree, previous, (tail(tree, previous) || "") <> tail)
      end
    else
      tree
    end
  end

  # Fully removes a subtree from the arena so stale ids cannot resurface.
  defp drop_subtree(tree, id) do
    ids = iter(tree, id)
    tree = detach(tree, id)
    %{tree | nodes: Map.drop(tree.nodes, ids)}
  end

  @doc "Replaces `old` with `new` at the same position among its parent's children."
  @spec replace(t, id, id) :: t
  def replace(tree, old, new) do
    case parent(tree, old) do
      nil ->
        tree

      parent ->
        position = index_in_parent(tree, old)

        tree
        |> detach(old)
        |> insert(parent, position, new)
    end
  end

  # ## Navigation ----------------------------------------------------------

  @spec index_in_parent(t, id) :: non_neg_integer | nil
  def index_in_parent(tree, id) do
    case parent(tree, id) do
      nil -> nil
      parent -> Enum.find_index(children(tree, parent), &(&1 == id))
    end
  end

  @spec next_sibling(t, id) :: id | nil
  def next_sibling(tree, id), do: sibling_at(tree, id, +1)

  @spec prev_sibling(t, id) :: id | nil
  def prev_sibling(tree, id), do: sibling_at(tree, id, -1)

  defp sibling_at(tree, id, offset) do
    with parent when not is_nil(parent) <- parent(tree, id),
         index when not is_nil(index) <- index_in_parent(tree, id),
         true <- index + offset >= 0 do
      Enum.at(children(tree, parent), index + offset)
    else
      _ -> nil
    end
  end

  @doc "Following siblings in document order."
  @spec next_siblings(t, id) :: [id]
  def next_siblings(tree, id) do
    case {parent(tree, id), index_in_parent(tree, id)} do
      {nil, _} -> []
      {parent, index} -> children(tree, parent) |> Enum.drop(index + 1)
    end
  end

  @doc "Preceding siblings, nearest first (matching lxml's `itersiblings(preceding=True)`)."
  @spec prev_siblings(t, id) :: [id]
  def prev_siblings(tree, id) do
    case {parent(tree, id), index_in_parent(tree, id)} do
      {nil, _} -> []
      {parent, index} -> children(tree, parent) |> Enum.take(index) |> Enum.reverse()
    end
  end

  @doc "Ancestors from the immediate parent up to the root."
  @spec ancestors(t, id) :: [id]
  def ancestors(tree, id) do
    case parent(tree, id) do
      nil -> []
      parent -> [parent | ancestors(tree, parent)]
    end
  end

  @doc "Whether any ancestor of `id` carries one of `tags`."
  @spec has_ancestor?(t, id, [String.t()]) :: boolean
  def has_ancestor?(tree, id, tags),
    do: Enum.any?(ancestors(tree, id), &(tag(tree, &1) in tags))

  @doc """
  The element and all its descendants in document order.

  With `tags`, only matching elements are returned — but the walk still descends
  through non-matching ones, exactly like `lxml`'s `iter(*tags)`.
  """
  @spec iter(t, id, [String.t()] | nil) :: [id]
  def iter(tree, id, tags \\ nil) do
    tree |> do_iter(id, tags) |> :lists.reverse()
  end

  defp do_iter(tree, id, tags, acc \\ []) do
    acc = if is_nil(tags) or tag(tree, id) in tags, do: [id | acc], else: acc
    Enum.reduce(children(tree, id), acc, &do_iter(tree, &1, tags, &2))
  end

  @doc "Descendants in document order, excluding the element itself."
  @spec iterdescendants(t, id, [String.t()] | nil) :: [id]
  def iterdescendants(tree, id, tags \\ nil) do
    children(tree, id)
    |> Enum.flat_map(&iter(tree, &1, tags))
  end

  @doc "Direct children carrying one of `tags` (lxml's `findall(\"tag\")`)."
  @spec find_children(t, id, String.t() | [String.t()]) :: [id]
  def find_children(tree, id, tags) do
    tags = List.wrap(tags)
    children(tree, id) |> Enum.filter(&(tag(tree, &1) in tags))
  end

  @doc "Descendants carrying one of `tags` (lxml's `findall(\".//tag\")`)."
  @spec find_all(t, id, String.t() | [String.t()]) :: [id]
  def find_all(tree, id, tags), do: iterdescendants(tree, id, List.wrap(tags))

  @doc "First descendant carrying `tag`, or `nil`."
  @spec find(t, id, String.t() | [String.t()]) :: id | nil
  def find(tree, id, tags), do: find_all(tree, id, tags) |> List.first()

  # ## Text ----------------------------------------------------------------

  @doc """
  All text inside the element, in document order.

  Follows `lxml`'s `itertext()`: the element's own `text`, then for each child
  its text recursively followed by that child's `tail`. The element's own tail
  belongs to its parent and is excluded.
  """
  @spec itertext(t, id) :: [String.t()]
  def itertext(tree, id), do: tree |> collect_text(id, []) |> :lists.reverse()

  defp collect_text(tree, id, acc) do
    acc = prepend_text(acc, text(tree, id))

    Enum.reduce(children(tree, id), acc, fn child, acc ->
      tree |> collect_text(child, acc) |> prepend_text(tail(tree, child))
    end)
  end

  defp prepend_text(acc, text) when text in [nil, ""], do: acc
  defp prepend_text(acc, text), do: [text | acc]

  @doc "All text inside the element as one string (lxml's `text_content()`)."
  @spec text_content(t, id) :: String.t()
  def text_content(tree, id), do: tree |> itertext(id) |> IO.iodata_to_binary()

  # ## Copying -------------------------------------------------------------

  @doc """
  Copies a subtree into the same arena, returning the detached copy.

  The copy shares no ids with the original, so mutating one never affects the
  other — the guarantee trafilatura relies on when it keeps a backup tree to fall
  back to.
  """
  @spec deep_copy(t, id) :: {t, id}
  def deep_copy(tree, id) do
    {tree, copy} = copy_node(tree, id)
    {put_tail(tree, copy, nil), copy}
  end

  @doc "Like `deep_copy/2` but keeps the tail, for copies spliced back into a document."
  @spec deep_copy_with_tail(t, id) :: {t, id}
  def deep_copy_with_tail(tree, id), do: copy_node(tree, id)

  defp copy_node(tree, id) do
    source = node(tree, id)
    {tree, copy} = create(tree, source.tag, source.attrs)

    tree =
      tree
      |> put_text(copy, source.text)
      |> put_tail(copy, source.tail)

    Enum.reduce(source.children, {tree, copy}, fn child, {tree, copy} ->
      {tree, child_copy} = copy_node(tree, child)
      {append(tree, copy, child_copy), copy}
    end)
  end

  # ## Bulk tag surgery ----------------------------------------------------

  @doc """
  Removes the named elements but keeps their text and children in place.

  This is `lxml`'s `strip_tags`: the element dissolves, its text merges into
  whatever precedes it, its children move up into its position, and its tail
  merges onto the last of them.
  """
  @spec strip_tags(t, id, [String.t()]) :: t
  def strip_tags(tree, root, tags) do
    # Bottom-up, so stripping a nested match cannot invalidate an outer one.
    tree
    |> iter(root, tags)
    |> Enum.reverse()
    |> Enum.reduce(tree, &strip_one_tag(&2, &1))
  end

  defp strip_one_tag(tree, id) do
    case parent(tree, id) do
      nil ->
        tree

      parent ->
        position = index_in_parent(tree, id)
        kids = children(tree, id)

        tree
        |> merge_text_before(id, parent, text(tree, id))
        |> reparent_children(parent, position, kids)
        |> merge_tail_after(id, parent, kids)
        |> then(&%{&1 | nodes: Map.delete(&1.nodes, id)})
        |> update_node(parent, &%{&1 | children: List.delete(&1.children, id)})
    end
  end

  defp merge_text_before(tree, _id, _parent, text) when text in [nil, ""], do: tree

  defp merge_text_before(tree, id, parent, text) do
    case prev_sibling(tree, id) do
      nil -> put_text(tree, parent, (text(tree, parent) || "") <> text)
      previous -> put_tail(tree, previous, (tail(tree, previous) || "") <> text)
    end
  end

  defp reparent_children(tree, parent, position, kids) do
    kids
    |> Enum.with_index(position)
    |> Enum.reduce(tree, fn {child, index}, tree -> insert(tree, parent, index, child) end)
  end

  defp merge_tail_after(tree, id, parent, kids) do
    tail = tail(tree, id)

    cond do
      tail in [nil, ""] ->
        tree

      kids != [] ->
        last = List.last(kids)
        put_tail(tree, last, (tail(tree, last) || "") <> tail)

      true ->
        merge_text_before(tree, id, parent, tail)
    end
  end

  @doc """
  Removes the named elements *including* their content (lxml's `strip_elements`).

  Tails are preserved, matching lxml's `with_tail=True` default.
  """
  @spec strip_elements(t, id, [String.t()]) :: t
  def strip_elements(tree, root, tags) do
    tree
    |> iter(root, tags)
    |> Enum.reverse()
    |> Enum.reduce(tree, fn id, tree ->
      if exists?(tree, id), do: delete_element(tree, id), else: tree
    end)
  end

  # ## Parsing and serialization -------------------------------------------

  @doc """
  Parses an HTML document into a tree.

  Floki gives us a nested list where text is interleaved with elements; the
  conversion below redistributes those runs into lxml's `text`/`tail` split.

  Input that is not HTML at all yields an empty tree — see `dubious?/2`.
  """
  @spec parse(binary) :: t
  def parse(html) when is_binary(html) do
    case Chushutsu.Tree.Parser.document(html) do
      {:ok, floki} ->
        tree = from_floki(floki)
        if dubious?(tree, html), do: new(), else: tree

      :error ->
        new()
    end
  end

  @doc """
  Whether the input looks like something other than an HTML document.

  lxml rejects input that neither mentions `html` near the start nor parses into
  real structure. An HTML5 parser can't reproduce that for free — it synthesizes
  `<html><head><body>` around anything, so a plain sentence would otherwise come
  back as a perfectly good one-paragraph document.
  """
  @spec dubious?(t, binary) :: boolean
  def dubious?(tree, html) do
    prefix = binary_part(html, 0, min(50, byte_size(html)))
    not Regex.match?(~r/html/i, prefix) and not has_real_elements?(tree)
  end

  defp has_real_elements?(%__MODULE__{root: nil}), do: false

  defp has_real_elements?(tree) do
    tree
    |> iterdescendants(tree.root)
    |> Enum.any?(&(tag(tree, &1) not in ["head", "body"]))
  end

  @doc "Builds a tree from an already-parsed Floki document."
  @spec from_floki(term) :: t
  def from_floki(floki) do
    case floki |> List.wrap() |> Enum.find(&match?({tag, _, _} when is_binary(tag), &1)) do
      nil ->
        new()

      element ->
        {tree, root} = build(new(), element)
        %{tree | root: root}
    end
  end

  defp build(tree, {tag, attrs, children}) do
    {tree, id} = create(tree, downcase_tag(tag), Enum.map(attrs, fn {k, v} -> {String.downcase(k), v} end))
    add_children(tree, id, children)
  end

  defp downcase_tag(tag) when is_binary(tag), do: String.downcase(tag)

  # Text runs land on `text` when they precede every child, and otherwise on the
  # `tail` of the child they follow — accumulating so several runs merge.
  defp add_children(tree, parent, floki_children) do
    {tree, _last} =
      Enum.reduce(floki_children, {tree, nil}, fn child, {tree, last} ->
        case child do
          text when is_binary(text) ->
            {append_text(tree, parent, last, text), last}

          {tag, _, _} = element when is_binary(tag) ->
            {tree, child_id} = build(tree, element)
            {append(tree, parent, child_id), child_id}

          _other ->
            # comments, doctypes and processing instructions carry no text
            {tree, last}
        end
      end)

    {tree, parent}
  end

  defp append_text(tree, parent, nil, text),
    do: put_text(tree, parent, (text(tree, parent) || "") <> text)

  defp append_text(tree, _parent, last, text),
    do: put_tail(tree, last, (tail(tree, last) || "") <> text)

  @doc "Serializes a subtree back to HTML."
  @spec to_html(t, id) :: String.t()
  def to_html(tree, id), do: tree |> render(id, false) |> IO.iodata_to_binary()

  @doc "Serializes a subtree, including its tail text."
  @spec to_html_with_tail(t, id) :: String.t()
  def to_html_with_tail(tree, id), do: tree |> render(id, true) |> IO.iodata_to_binary()

  defp render(tree, id, with_tail) do
    node = node(tree, id)
    open = [?<, node.tag, render_attrs(node.attrs), ?>]

    body =
      if node.tag in @void_tags and node.children == [] do
        []
      else
        [escape(node.text), Enum.map(node.children, &render(tree, &1, true)), "</", node.tag, ?>]
      end

    [open, body, if(with_tail, do: escape(node.tail), else: [])]
  end

  defp render_attrs(attrs) do
    Enum.map(attrs, fn {key, value} -> [?\s, key, ~s|="|, escape_attr(value), ?"] end)
  end

  defp escape(nil), do: []

  defp escape(text),
    do: text |> String.replace("&", "&amp;") |> String.replace("<", "&lt;") |> String.replace(">", "&gt;")

  defp escape_attr(value), do: value |> escape() |> String.replace(~s|"|, "&quot;")
end
