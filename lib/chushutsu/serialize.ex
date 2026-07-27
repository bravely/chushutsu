defmodule Chushutsu.Serialize do
  @moduledoc "Dispatches a `Chushutsu.Document` to the requested output format."

  alias Chushutsu.{Document, Options, Serialize, Settings, Text, Tree}

  @doc "Renders a document in the format named by `options`."
  @spec render(Document.t(), Options.t()) :: String.t()
  def render(%Document{} = document, %Options{} = options) do
    case options.format do
      format when format in [:txt, :markdown, :python] -> text_output(document, options)
      :json -> Serialize.Json.render(document, options)
      :csv -> Serialize.Csv.render(document, options)
      :html -> Serialize.Html.render(document, options)
      format when format in [:xml, :xmltei] -> Serialize.Xml.render(document, options)
    end
    |> Text.normalize_unicode()
  end

  defp text_output(document, options) do
    body = Serialize.Text.render(document.tree, document.body, options.formatting)
    header = if options.with_metadata, do: yaml_header(document), else: ""

    comments =
      if document.comments_body,
        do: Serialize.Text.render(document.tree, document.comments_body, options.formatting),
        else: ""

    "#{header}#{body}\n#{comments}" |> String.trim()
  end

  @header_fields ~w(title author url hostname description sitename date categories tags fingerprint id license)a

  # Metadata rides along as a YAML front-matter block, so values that would
  # otherwise produce invalid YAML (a title containing ": ", a reserved word)
  # have to be quoted.
  defp yaml_header(document) do
    lines =
      Enum.flat_map(@header_fields, fn field ->
        case Map.get(document, field) do
          value when value in [nil, "", []] -> []
          value when is_binary(value) -> ["#{field}: #{yaml_scalar(value)}"]
          value when is_list(value) -> ["#{field}: #{inspect(value, charlists: :as_lists)}"]
          value -> ["#{field}: #{value}"]
        end
      end)

    "---\n" <> Enum.map_join(lines, "", &(&1 <> "\n")) <> "---\n"
  end

  @yaml_reserved ~w(true false yes no on off y n null none ~)

  defp yaml_scalar(value) do
    if plain_yaml?(value), do: value, else: Jason.encode!(value)
  end

  defp plain_yaml?(value) do
    value != "" and value == String.trim(value) and
      alpha_first?(value) and
      not String.contains?(value, ": ") and
      not String.contains?(value, " #") and
      not String.ends_with?(value, ":") and
      String.downcase(value) not in @yaml_reserved and
      not String.match?(value, ~r/[\x{0}-\x{1f}\x{7f}]/u)
  end

  defp alpha_first?(<<first::utf8, _rest::binary>>), do: String.match?(<<first::utf8>>, ~r/^\p{L}$/u)
  defp alpha_first?(_other), do: false

  @doc """
  Strips attributes from elements not allowed to keep them.

  Shared by the XML and TEI writers.
  """
  @spec clean_attributes(Tree.t(), Tree.id()) :: Tree.t()
  def clean_attributes(tree, root) do
    tree
    |> Tree.iter(root)
    |> Enum.reduce(tree, fn id, tree ->
      if Tree.tag(tree, id) in Settings.with_attributes(),
        do: tree,
        else: Tree.clear_attrs(tree, id)
    end)
  end

  @doc "Removes elements left with neither text nor children."
  @spec remove_empty_elements(Tree.t(), Tree.id()) :: Tree.t()
  def remove_empty_elements(tree, root) do
    tree
    |> Tree.iter(root)
    |> Enum.reverse()
    |> Enum.reduce(tree, fn id, tree ->
      parent = Tree.parent(tree, id)

      # elements inside <code> are load-bearing whitespace
      removable =
        Tree.exists?(tree, id) and Tree.children(tree, id) == [] and
          not Text.text_chars?(Tree.text(tree, id)) and not Text.text_chars?(Tree.tail(tree, id)) and
          parent != nil and Tree.tag(tree, id) != "graphic" and
          Tree.tag(tree, parent) != "code"

      if removable, do: Tree.delete_element(tree, id), else: tree
    end)
  end
end
