defmodule Chushutsu.Serialize.Xml do
  @moduledoc """
  XML and TEI-XML output.

  Plain XML wraps the extracted body and comments in a `<doc>` carrying the
  metadata as attributes. TEI adds a full `teiHeader` and, because the TEI
  content model is stricter than the extractor's own vocabulary, a repair pass
  that rehomes elements the standard does not allow where they ended up.
  """

  alias Chushutsu.{Document, Options, Serialize, Settings, Text, Tree}

  @tei_remove_tail ~w(ab p)
  @tei_div_siblings ~w(p list table quote ab)
  @heading_levels ~w(1 2 3 4 5 6)

  @doc "Renders a document as XML or TEI-XML."
  @spec render(Document.t(), Options.t()) :: String.t()
  def render(%Document{} = document, %Options{format: format}) do
    tree = document.tree

    {tree, body} = prepare(tree, document.body)
    {tree, comments} = prepare(tree, document.comments_body)

    {tree, root} =
      if format == :xmltei,
        do: build_tei(tree, document, body, comments),
        else: build_xml(tree, document, body, comments)

    declaration(format) <> pretty(tree, root, 0)
  end

  defp declaration(:xmltei), do: ~s|<?xml version="1.0" encoding="UTF-8"?>\n|
  defp declaration(_format), do: ""

  defp prepare(tree, nil) do
    {tree, id} = Tree.create(tree, "body")
    {tree, id}
  end

  defp prepare(tree, id) do
    {tree, copy} = Tree.deep_copy(tree, id)

    tree =
      tree
      |> strip_double_tags(copy)
      |> Serialize.remove_empty_elements(copy)

    {tree, copy}
  end

  # ## Plain XML -----------------------------------------------------------

  defp build_xml(tree, document, body, comments) do
    {tree, root} = Tree.create(tree, "doc")
    tree = add_meta_attributes(tree, root, document)

    tree =
      tree
      |> Tree.put_tag(body, "main")
      |> Serialize.clean_attributes(body)
      |> Tree.append(root, body)
      |> Tree.put_tag(comments, "comments")
      |> Serialize.clean_attributes(comments)
      |> Tree.append(root, comments)

    {tree, root}
  end

  defp add_meta_attributes(tree, root, document) do
    Enum.reduce(Settings.meta_attributes(), tree, fn field, tree ->
      case Map.get(document, field) do
        value when value in [nil, "", []] -> tree
        value when is_binary(value) -> Tree.put_attr(tree, root, to_string(field), value)
        value when is_list(value) -> Tree.put_attr(tree, root, to_string(field), Enum.join(value, ";"))
        _other -> tree
      end
    end)
  end

  # ## TEI -----------------------------------------------------------------

  defp build_tei(tree, document, body, comments) do
    {tree, root} = Tree.create(tree, "TEI", [{"xmlns", "http://www.tei-c.org/ns/1.0"}])
    tree = write_header(tree, root, document)

    {tree, text_elem} = Tree.create_child(tree, root, "text")
    {tree, text_body} = Tree.create_child(tree, text_elem, "body")

    tree =
      tree
      |> Serialize.clean_attributes(body)
      |> Tree.put_tag(body, "div")
      |> Tree.put_attr(body, "type", "entry")
      |> Tree.append(text_body, body)
      |> Serialize.clean_attributes(comments)
      |> Tree.put_tag(comments, "div")
      |> Tree.put_attr(comments, "type", "comments")
      |> Tree.append(text_body, comments)

    {check_tei(tree, text_body), root}
  end

  defp write_header(tree, root, document) do
    {tree, header} = Tree.create_child(tree, root, "teiHeader")
    {tree, filedesc} = Tree.create_child(tree, header, "fileDesc")

    tree = title_statement(tree, filedesc, document)
    publisher = publisher_string(document)
    tree = publication_statement(tree, filedesc, document, publisher)
    tree = notes_statement(tree, filedesc, document)
    tree = source_description(tree, filedesc, document, publisher)
    tree = profile_description(tree, header, document)
    encoding_description(tree, header)
  end

  defp title_statement(tree, parent, document) do
    {tree, stmt} = Tree.create_child(tree, parent, "titleStmt")
    {tree, title} = Tree.create_child(tree, stmt, "title", [{"type", "main"}])
    tree = Tree.put_text(tree, title, document.title)

    if present?(document.author) do
      {tree, author} = Tree.create_child(tree, stmt, "author")
      Tree.put_text(tree, author, document.author)
    else
      tree
    end
  end

  defp publication_statement(tree, parent, document, publisher) do
    {tree, stmt} = Tree.create_child(tree, parent, "publicationStmt")

    if present?(document.license) do
      {tree, pub} = Tree.create_child(tree, stmt, "publisher")
      tree = Tree.put_text(tree, pub, publisher)
      {tree, availability} = Tree.create_child(tree, stmt, "availability")
      {tree, paragraph} = Tree.create_child(tree, availability, "p")
      Tree.put_text(tree, paragraph, document.license)
    else
      # an empty paragraph keeps the element conformant
      {tree, _p} = Tree.create_child(tree, stmt, "p")
      tree
    end
  end

  defp notes_statement(tree, parent, document) do
    {tree, stmt} = Tree.create_child(tree, parent, "notesStmt")

    tree =
      if present?(document.id) do
        {tree, note} = Tree.create_child(tree, stmt, "note", [{"type", "id"}])
        Tree.put_text(tree, note, document.id)
      else
        tree
      end

    {tree, fingerprint} = Tree.create_child(tree, stmt, "note", [{"type", "fingerprint"}])
    Tree.put_text(tree, fingerprint, document.fingerprint)
  end

  defp source_description(tree, parent, document, publisher) do
    {tree, sourcedesc} = Tree.create_child(tree, parent, "sourceDesc")
    sigle = [document.sitename, document.date] |> Enum.filter(&present?/1) |> Enum.join(", ")

    {tree, bibl} = Tree.create_child(tree, sourcedesc, "bibl")
    citation = [document.title, presence(sigle)] |> Enum.filter(&present?/1) |> Enum.join(", ")
    tree = Tree.put_text(tree, bibl, citation)

    {tree, sigle_bibl} = Tree.create_child(tree, sourcedesc, "bibl", [{"type", "sigle"}])
    tree = Tree.put_text(tree, sigle_bibl, sigle)

    {tree, biblfull} = Tree.create_child(tree, sourcedesc, "biblFull")
    tree = title_statement(tree, biblfull, document)

    {tree, stmt} = Tree.create_child(tree, biblfull, "publicationStmt")
    {tree, pub} = Tree.create_child(tree, stmt, "publisher")
    tree = Tree.put_text(tree, pub, publisher)

    tree =
      if present?(document.url) do
        {tree, _ptr} = Tree.create_child(tree, stmt, "ptr", [{"type", "URL"}, {"target", document.url}])
        tree
      else
        tree
      end

    {tree, date} = Tree.create_child(tree, stmt, "date")
    Tree.put_text(tree, date, document.date)
  end

  defp profile_description(tree, header, document) do
    {tree, profile} = Tree.create_child(tree, header, "profileDesc")
    {tree, abstract} = Tree.create_child(tree, profile, "abstract")
    {tree, paragraph} = Tree.create_child(tree, abstract, "p")
    tree = Tree.put_text(tree, paragraph, document.description)

    tree = keywords(tree, profile, document)

    {tree, creation} = Tree.create_child(tree, profile, "creation")
    {tree, date} = Tree.create_child(tree, creation, "date", [{"type", "download"}])
    Tree.put_text(tree, date, document.filedate)
  end

  defp keywords(tree, profile, document) do
    if document.categories == [] and document.tags == [] do
      tree
    else
      {tree, textclass} = Tree.create_child(tree, profile, "textClass")
      {tree, keywords} = Tree.create_child(tree, textclass, "keywords")

      tree
      |> add_term(keywords, "categories", document.categories)
      |> add_term(keywords, "tags", document.tags)
    end
  end

  defp add_term(tree, _keywords, _type, []), do: tree

  defp add_term(tree, keywords, type, values) do
    {tree, term} = Tree.create_child(tree, keywords, "term", [{"type", type}])
    Tree.put_text(tree, term, Enum.join(values, ","))
  end

  defp encoding_description(tree, header) do
    {tree, encoding} = Tree.create_child(tree, header, "encodingDesc")
    {tree, appinfo} = Tree.create_child(tree, encoding, "appInfo")

    {tree, application} =
      Tree.create_child(tree, appinfo, "application", [
        {"version", Application.spec(:chushutsu, :vsn) |> to_string()},
        {"ident", "Chushutsu"}
      ])

    {tree, label} = Tree.create_child(tree, application, "label")
    tree = Tree.put_text(tree, label, "Chushutsu")

    {tree, _ptr} =
      Tree.create_child(tree, application, "ptr", [{"target", "https://github.com/adbar/trafilatura"}])

    tree
  end

  defp publisher_string(document) do
    cond do
      present?(document.hostname) and present?(document.sitename) ->
        "#{String.trim(document.sitename)} (#{document.hostname})"

      present?(document.hostname) ->
        document.hostname

      present?(document.sitename) ->
        document.sitename

      true ->
        "N/A"
    end
  end

  # ## TEI conformance repair ----------------------------------------------

  defp check_tei(tree, root) do
    tree
    |> convert_heads(root)
    |> convert_div_line_breaks(root)
    |> repair_elements(root)
  end

  # TEI has no <head> in this position; it becomes an <ab type="header">.
  defp convert_heads(tree, root) do
    tree
    |> Tree.iter(root, ["head"])
    |> Enum.reduce(tree, fn id, tree ->
      if Tree.exists?(tree, id) do
        tree
        |> Tree.put_tag(id, "ab")
        |> Tree.put_attr(id, "type", "header")
        |> flatten_complex_head(id)
      else
        tree
      end
    end)
  end

  # A heading containing paragraphs is flattened, with <lb/> standing in for the
  # paragraph breaks TEI will not allow here.
  defp flatten_complex_head(tree, id) do
    tree
    |> Tree.find_children(id, "p")
    |> Enum.reduce(tree, fn paragraph, tree ->
      text = Tree.text(tree, paragraph)
      position = Tree.index_in_parent(tree, paragraph)

      tree = Tree.delete_element(tree, paragraph, keep_tail: true)

      if Text.text_chars?(text) do
        {tree, lb} = Tree.create(tree, "lb")
        tree |> Tree.insert(id, position, lb) |> Tree.put_tail(lb, text)
      else
        tree
      end
    end)
  end

  defp convert_div_line_breaks(tree, root) do
    tree
    |> Tree.iter(root, ["lb"])
    |> Enum.filter(&(Tree.tag(tree, Tree.parent(tree, &1)) == "div"))
    |> Enum.reduce(tree, fn id, tree ->
      if Text.text_chars?(Tree.tail(tree, id)) do
        tree
        |> Tree.put_tag(id, "p")
        |> Tree.put_text(id, Tree.tail(tree, id))
        |> Tree.put_tail(id, nil)
      else
        tree
      end
    end)
  end

  defp repair_elements(tree, root) do
    tree
    |> Tree.iterdescendants(root)
    |> Enum.reduce(tree, fn id, tree ->
      cond do
        not Tree.exists?(tree, id) ->
          tree

        Tree.tag(tree, id) not in Settings.tei_valid_tags() ->
          merge_with_parent(tree, id)

        true ->
          tree
          |> handle_tail(id)
          |> drop_invalid_attributes(id)
      end
    end)
  end

  defp handle_tail(tree, id) do
    tag = Tree.tag(tree, id)
    tail = Text.normalize_space(Tree.tail(tree, id))

    cond do
      tag not in @tei_remove_tail or tail == "" ->
        tree

      tag == "p" ->
        text = [Tree.text(tree, id), tail] |> Enum.filter(&present?/1) |> Enum.join(" ")
        tree |> Tree.put_text(id, text) |> Tree.put_tail(id, nil)

      true ->
        {tree, sibling} = Tree.create(tree, "p")
        tree = Tree.put_text(tree, sibling, tail)
        parent = Tree.parent(tree, id)

        tree
        |> Tree.insert(parent, Tree.index_in_parent(tree, id) + 1, sibling)
        |> Tree.put_tail(id, nil)
    end
  end

  defp drop_invalid_attributes(tree, id) do
    tree
    |> Tree.attrs(id)
    |> Enum.reject(fn {name, _value} -> name in Settings.tei_valid_attrs() end)
    |> Enum.reduce(tree, fn {name, _value}, tree -> Tree.delete_attr(tree, id, name) end)
  end

  # Dissolves an element into its parent, keeping its text where it stood.
  defp merge_with_parent(tree, id) do
    parent = Tree.parent(tree, id)

    if parent do
      text = tree |> Tree.itertext(id) |> Enum.join()
      full = text <> (Tree.tail(tree, id) || "")

      case Tree.prev_sibling(tree, id) do
        nil ->
          existing = Tree.text(tree, parent)
          joined = if existing, do: "#{existing} #{full}", else: full
          tree |> Tree.put_text(parent, joined) |> Tree.delete_element(id, keep_tail: false)

        previous ->
          existing = Tree.tail(tree, previous)
          joined = if existing, do: "#{existing} #{full}", else: full
          tree |> Tree.put_tail(previous, joined) |> Tree.delete_element(id, keep_tail: false)
      end
    else
      tree
    end
  end

  # ## Rendering -----------------------------------------------------------

  defp pretty(tree, id, depth) do
    indent = String.duplicate("  ", depth)
    tag = Tree.tag(tree, id)
    attrs = Enum.map_join(Tree.attrs(tree, id), "", fn {k, v} -> ~s| #{k}="#{escape_attr(v)}"| end)
    children = Tree.children(tree, id)
    text = Tree.text(tree, id)

    cond do
      children == [] and text in [nil, ""] ->
        "#{indent}<#{tag}#{attrs}/>\n"

      children == [] ->
        "#{indent}<#{tag}#{attrs}>#{escape(text)}</#{tag}>\n"

      true ->
        inner = Enum.map_join(children, "", &(pretty(tree, &1, depth + 1) <> tail_text(tree, &1)))
        "#{indent}<#{tag}#{attrs}>#{escape(text)}\n#{inner}#{indent}</#{tag}>\n"
    end
  end

  defp tail_text(tree, id) do
    case Tree.tail(tree, id) do
      tail when tail in [nil, ""] -> ""
      tail -> escape(tail)
    end
  end

  defp escape(nil), do: ""

  defp escape(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end

  defp escape_attr(value), do: value |> escape() |> String.replace(~s|"|, "&quot;")

  defp strip_double_tags(tree, root) do
    tree
    |> Tree.iter(root, ~w(head code p))
    |> Enum.reverse()
    |> Enum.reduce(tree, fn id, tree ->
      if Tree.exists?(tree, id), do: dissolve_same_tag_descendants(tree, id), else: tree
    end)
  end

  defp dissolve_same_tag_descendants(tree, id) do
    tag = Tree.tag(tree, id)

    tree
    |> Tree.iterdescendants(id, ~w(code head p))
    |> Enum.filter(fn sub ->
      Tree.tag(tree, sub) == tag and Tree.tag(tree, Tree.parent(tree, sub)) not in Settings.nesting_whitelist()
    end)
    |> Enum.reduce(tree, fn sub, tree ->
      if Tree.exists?(tree, sub), do: merge_with_parent(tree, sub), else: tree
    end)
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""
  defp presence(""), do: nil
  defp presence(value), do: value

  @doc false
  def heading_levels, do: @heading_levels

  @doc false
  def tei_div_siblings, do: @tei_div_siblings
end
