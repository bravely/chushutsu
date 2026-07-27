defmodule Chushutsu.BaselineTest do
  use ExUnit.Case, async: true

  import Chushutsu.TreeHelpers

  alias Chushutsu.{Baseline, Tree}

  defp run(html) do
    tree = Tree.parse(html)
    {_tree, _body, text, length} = Baseline.extract(tree, Tree.root(tree))
    {text, length}
  end

  defp page(body), do: "<html><body>#{body}</body></html>"

  describe "embedded JSON" do
    test "prefers schema.org articleBody over the markup" do
      long = String.duplicate("The embedded article body text. ", 8)

      html =
        page("""
        <script type="application/ld+json">
        {"@type":"NewsArticle","articleBody":"#{long}"}
        </script>
        <p>markup paragraph</p>
        """)

      {text, _length} = run(html)
      assert text =~ "The embedded article body text."
      refute text =~ "markup paragraph"
    end

    test "reads recipe instructions from step objects" do
      steps =
        Enum.map_join(1..6, ",", fn i ->
          ~s|{"@type":"HowToStep","text":"Step number #{i} with enough words to count."}|
        end)

      html = page(~s|<script type="application/ld+json">{"@type":"HowTo","step":[#{steps}]}</script>|)

      {text, _length} = run(html)
      assert text =~ "Step number 1"
      assert text =~ "Step number 6"
    end

    test "reads a FAQ accepted answer" do
      answer = String.duplicate("The answer to the question. ", 6)

      html =
        page(
          ~s|<script type="application/ld+json">{"@type":"FAQPage","mainEntity":{"@type":"Question","acceptedAnswer":{"@type":"Answer","text":"#{answer}"}}}</script>|
        )

      {text, _length} = run(html)
      assert text =~ "The answer to the question."
    end

    test "renders markup embedded inside a JSON value" do
      body = "<p>" <> String.duplicate("Escaped markup content. ", 8) <> "</p>"

      html =
        page(~s|<script type="application/ld+json">{"@type":"Article","articleBody":#{Jason.encode!(body)}}</script>|)

      {text, _length} = run(html)
      assert text =~ "Escaped markup content."
      refute text =~ "<p>"
    end

    test "ignores malformed JSON rather than failing" do
      html =
        page(
          ~s|<script type="application/ld+json">{"articleBody": not json}</script><p>#{String.duplicate("fallback text ", 20)}</p>|
        )

      {text, _length} = run(html)
      assert text =~ "fallback text"
    end
  end

  describe "article elements" do
    test "takes article text when there is no embedded JSON" do
      html = page("<article><p>#{String.duplicate("article content ", 20)}</p></article>")

      {text, _length} = run(html)
      assert text =~ "article content"
    end

    test "drops articles much smaller than the dominant one" do
      big = String.duplicate("the main story text ", 40)
      html = page("<article><p>#{big}</p></article><article><p>#{String.duplicate("teaser ", 3)}</p></article>")

      {text, _length} = run(html)
      assert text =~ "the main story text"
      refute text =~ "teaser"
    end

    test "keeps similarly-sized articles, which are forum posts" do
      one = String.duplicate("first post content ", 20)
      two = String.duplicate("second post content ", 20)
      html = page("<article><p>#{one}</p></article><article><p>#{two}</p></article>")

      {text, _length} = run(html)
      assert text =~ "first post content"
      assert text =~ "second post content"
    end
  end

  describe "paragraph fallback" do
    test "collects paragraph text" do
      html =
        page(
          "<div><p>#{String.duplicate("paragraph one ", 10)}</p><p>#{String.duplicate("paragraph two ", 10)}</p></div>"
        )

      {text, _length} = run(html)
      assert text =~ "paragraph one"
      assert text =~ "paragraph two"
    end

    test "drops a paragraph duplicated by its container" do
      inner = String.duplicate("nested duplicated content ", 6)
      html = page("<blockquote><p>#{inner}</p></blockquote>")

      {text, _length} = run(html)
      # the blockquote is collected first; its nested <p> repeats that text
      assert text |> String.split("nested duplicated content") |> length() < 14
    end
  end

  describe "basic_cleaning/2" do
    test "removes scripts, footers and consent banners" do
      {tree, root} =
        parse(~s|<p>keep</p><footer>foot</footer><script>js</script><div class="cookie-banner">consent</div>|)

      tree = Baseline.basic_cleaning(tree, root)

      assert text(tree, root) == "keep"
    end

    test "leaves a page about cookies alone" do
      # anchored compounds only; a bare "cookie" token is content here
      {tree, root} = parse(~s|<div class="cookie-recipes">Chocolate cookies</div>|)
      tree = Baseline.basic_cleaning(tree, root)

      assert text(tree, root) =~ "Chocolate cookies"
    end
  end

  describe "html_to_txt/3" do
    test "flattens the page and spaces block boundaries" do
      tree = Tree.parse(page("<div>one</div><div>two</div>"))
      assert Baseline.html_to_txt(tree, Tree.root(tree)) == "one two"
    end

    test "strips chrome by default and keeps it when asked not to" do
      tree = Tree.parse(page("<p>body</p><footer>foot</footer>"))
      root = Tree.root(tree)

      assert Baseline.html_to_txt(tree, root) == "body"
      assert Baseline.html_to_txt(tree, root, clean: false) =~ "foot"
    end

    test "leaves the caller's tree untouched" do
      tree = Tree.parse(page("<p>body</p><footer>foot</footer>"))
      root = Tree.root(tree)

      _ = Baseline.html_to_txt(tree, root)
      assert Tree.find(tree, root, "footer") != nil
    end
  end

  describe "last resort" do
    test "dumps the whole body when nothing else yields content" do
      html = page("<div><span>#{String.duplicate("loose text ", 20)}</span></div>")

      {text, length} = run(html)
      assert text =~ "loose text"
      assert length > 0
    end

    test "an empty page yields nothing" do
      assert {"", 0} = run(page(""))
    end
  end
end
