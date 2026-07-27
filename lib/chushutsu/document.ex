defmodule Chushutsu.Document do
  @moduledoc """
  The result of an extraction: the rendered text plus whatever metadata was found.

  `body` and `comments_body` hold element ids into `tree`, so callers that want
  the structure rather than the rendered string can walk it themselves.
  """

  defstruct title: nil,
            author: nil,
            url: nil,
            hostname: nil,
            description: nil,
            sitename: nil,
            date: nil,
            categories: [],
            tags: [],
            fingerprint: nil,
            id: nil,
            license: nil,
            image: nil,
            pagetype: nil,
            filedate: nil,
            language: nil,
            text: nil,
            raw_text: nil,
            comments: nil,
            tree: nil,
            body: nil,
            comments_body: nil

  @type t :: %__MODULE__{}

  @doc "The document as a plain map, with the tree handles dropped."
  @spec to_map(t) :: map
  def to_map(%__MODULE__{} = document) do
    document
    |> Map.from_struct()
    |> Map.drop([:tree, :body, :comments_body])
  end
end
