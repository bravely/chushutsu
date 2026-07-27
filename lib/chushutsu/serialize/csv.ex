defmodule Chushutsu.Serialize.Csv do
  @moduledoc "Tab-separated output, one row per document."

  alias Chushutsu.{Document, Options, Serialize}

  @null "null"
  @delimiter "\t"

  @doc "Renders a document as a single delimited row."
  @spec render(Document.t(), Options.t()) :: String.t()
  def render(%Document{} = document, %Options{formatting: formatting}) do
    body = Serialize.Text.render(document.tree, document.body, formatting)
    comments = Serialize.Text.render(document.tree, document.comments_body, formatting)

    [
      document.url,
      document.id,
      document.fingerprint,
      document.hostname,
      document.title,
      document.image,
      document.date,
      body,
      comments,
      document.license,
      document.pagetype
    ]
    |> Enum.map_join(@delimiter, &field/1)
    |> Kernel.<>("\r\n")
  end

  defp field(value) when value in [nil, ""], do: @null

  defp field(value) do
    string = to_string(value)

    # minimal quoting, matching Python's csv.QUOTE_MINIMAL
    if String.contains?(string, [@delimiter, "\"", "\r", "\n"]),
      do: ~s|"#{String.replace(string, ~s|"|, ~s|""|)}"|,
      else: string
  end
end
