defmodule Chushutsu.Serialize.Html do
  @moduledoc """
  Simplified HTML output.

  The extractor's internal vocabulary is mapped back onto ordinary HTML tags, so
  the result is a clean article fragment rather than the page it came from.
  """

  alias Chushutsu.{Document, Options, Settings, Tree}

  @conversions %{
    "list" => "ul",
    "item" => "li",
    "code" => "pre",
    "quote" => "blockquote",
    "lb" => "br",
    "graphic" => "img",
    "ref" => "a",
    "row" => "tr"
  }

  @heading_levels ~w(1 2 3 4 5 6)

  @doc "Renders a document as an HTML fragment."
  @spec render(Document.t(), Options.t()) :: String.t()
  def render(%Document{} = document, %Options{with_metadata: with_metadata}) do
    {tree, body} = Tree.deep_copy(document.tree, document.body)
    tree = tree |> convert_tags(body) |> Tree.put_tag(body, "body")

    {tree, root} = Tree.create(tree, "html")
    tree = Tree.append(tree, root, body)

    tree = if with_metadata, do: add_head(tree, root, document), else: tree

    Tree.to_html(tree, root)
  end

  defp convert_tags(tree, root) do
    tree
    |> Tree.iter(root)
    |> Enum.reduce(tree, fn id, tree ->
      case convert(tree, id, Tree.tag(tree, id)) do
        nil -> tree
        new_tag -> tree |> Tree.put_tag(id, new_tag) |> fix_attributes(id, new_tag)
      end
    end)
  end

  defp convert(tree, id, "head") do
    level = Tree.attr(tree, id, "rend") || ""
    if String.slice(level, 1, 1) in @heading_levels, do: "h" <> String.slice(level, 1, 1), else: "h3"
  end

  defp convert(tree, id, "hi") do
    rend = Tree.attr(tree, id, "rend") || "#i"
    Settings.rend_tag_mapping() |> Enum.find_value("i", fn {tag, value} -> if value == rend, do: tag end)
  end

  defp convert(tree, id, "cell") do
    if Tree.attr(tree, id, "role") == "head", do: "th", else: "td"
  end

  defp convert(_tree, _id, tag), do: Map.get(@conversions, tag)

  defp fix_attributes(tree, id, "a") do
    target = Tree.attr(tree, id, "target", "")
    tree |> Tree.clear_attrs(id) |> Tree.put_attr(id, "href", target)
  end

  # <img> keeps src/alt/title; everything else loses its internal attributes
  defp fix_attributes(tree, _id, "img"), do: tree
  defp fix_attributes(tree, id, _tag), do: Tree.clear_attrs(tree, id)

  defp add_head(tree, root, document) do
    {tree, head} = Tree.create(tree, "head")

    tree =
      Enum.reduce(Settings.meta_attributes(), tree, fn field, tree ->
        case Map.get(document, field) do
          value when value in [nil, "", []] ->
            tree

          value ->
            content = if is_list(value), do: Enum.join(value, ";"), else: to_string(value)
            {tree, _meta} = Tree.create_child(tree, head, "meta", [{"name", to_string(field)}, {"content", content}])
            tree
        end
      end)

    Tree.insert(tree, root, 0, head)
  end
end
