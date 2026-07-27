defmodule Chushutsu.Serialize.Json do
  @moduledoc "JSON output, with the field renaming trafilatura applies."

  alias Chushutsu.{Document, Options, Serialize}

  @doc "Renders a document as a JSON object."
  @spec render(Document.t(), Options.t()) :: String.t()
  def render(%Document{} = document, %Options{with_metadata: with_metadata}) do
    # formatting is deliberately off: JSON consumers want plain text
    text = Serialize.Text.render(document.tree, document.body, false)
    comments = Serialize.Text.render(document.tree, document.comments_body, false)

    payload =
      if with_metadata do
        document
        |> Document.to_map()
        |> Map.drop([:url, :sitename, :description, :categories, :tags, :text, :comments, :raw_text])
        |> Map.merge(%{
          source: document.url,
          "source-hostname": document.sitename,
          excerpt: document.description,
          categories: Enum.join(document.categories || [], ";"),
          tags: Enum.join(document.tags || [], ";"),
          text: text
        })
      else
        %{text: text}
      end

    payload
    |> Map.put(:comments, comments)
    |> Jason.encode!()
  end
end
