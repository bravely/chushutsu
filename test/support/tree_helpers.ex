defmodule Chushutsu.TreeHelpers do
  @moduledoc """
  Helpers for driving the extraction internals from tests.

  Most stages take `{tree, root}` and return a new tree, so these wrap the
  boilerplate of parsing a fragment, running a stage and reading the result back
  out as something easy to assert on.
  """

  alias Chushutsu.{Options, Tree}

  @doc """
  Parses a body fragment and returns the tree with the `<body>` element.

  Working from `<body>` rather than the document root keeps the parser's own
  `<head>` out of the way — otherwise a converted `<h2>`, which also becomes a
  `head` element, is indistinguishable from it.
  """
  @spec parse(String.t()) :: {Tree.t(), Tree.id()}
  def parse(body) do
    tree = Tree.parse("<html><body>#{body}</body></html>")
    {tree, Tree.find(tree, Tree.root(tree), "body") || Tree.root(tree)}
  end

  @doc """
  Builds a tree directly from a Floki-shaped spec, with no HTML parsing.

  Necessary whenever the shape under test uses the extractor's own vocabulary:
  an HTML5 parser relocates a literal `<head>` and foster-parents stray content
  out of `<table>`, so round-tripping those through markup does not give you the
  tree you wrote.

      build({"body", [], [{"head", [{"rend", "h1"}], ["Title"]}]})
  """
  @spec build(tuple) :: {Tree.t(), Tree.id()}
  def build(spec) do
    tree = Tree.from_floki([spec])
    {tree, Tree.root(tree)}
  end

  @doc "Parses and returns the tree plus the first element matching `tag`."
  @spec parse_and_find(String.t(), String.t()) :: {Tree.t(), Tree.id()}
  def parse_and_find(body, tag) do
    {tree, root} = parse(body)
    {tree, Tree.find(tree, root, tag)}
  end

  @doc "Options with test-friendly defaults; pass overrides as a keyword list."
  @spec options(keyword) :: Options.t()
  def options(opts \\ []), do: Options.new(opts)

  @doc "A compact `tag[attr=value]` outline of a subtree, for structural assertions."
  @spec outline(Tree.t(), Tree.id() | nil) :: [String.t()]
  def outline(_tree, nil), do: []

  def outline(tree, id) do
    Enum.map(Tree.iter(tree, id), fn node ->
      attrs =
        tree
        |> Tree.attrs(node)
        |> Enum.map_join("", fn {k, v} -> "[#{k}=#{v}]" end)

      "#{Tree.tag(tree, node)}#{attrs}"
    end)
  end

  @doc "All text under an element, space-joined and trimmed."
  @spec text(Tree.t(), Tree.id() | nil) :: String.t()
  def text(_tree, nil), do: ""
  def text(tree, id), do: tree |> Tree.itertext(id) |> Enum.join(" ") |> String.trim()

  @doc "The tags of an element's direct children."
  @spec child_tags(Tree.t(), Tree.id()) :: [String.t()]
  def child_tags(tree, id), do: tree |> Tree.children(id) |> Enum.map(&Tree.tag(tree, &1))
end
