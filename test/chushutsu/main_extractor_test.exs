defmodule Chushutsu.MainExtractorTest do
  use ExUnit.Case, async: true

  import Chushutsu.TreeHelpers

  alias Chushutsu.{HtmlProcessing, MainExtractor, Serialize, Tree}

  # Runs the real pre-processing so handlers see the tag vocabulary they expect.
  defp convert(body, opts \\ []) do
    {tree, root} = parse(body)
    options = options(opts)
    {tree, root} = HtmlProcessing.tree_cleaning(tree, root, options)
    {HtmlProcessing.convert_tags(tree, root, options), root, options}
  end

  defp extract_body(body, opts \\ []) do
    {tree, root, options} = convert(body, opts)
    {tree, result, text, _length} = MainExtractor.extract_content(tree, root, options)
    {tree, result, text}
  end

  defp rendered(body, opts \\ []) do
    {tree, result, _text} = extract_body(body, opts)
    Serialize.Text.render(tree, result, Keyword.get(opts, :include_formatting, false))
  end

  describe "paragraphs" do
    test "keeps paragraph text and drops surrounding chrome" do
      body = """
      <nav class="menu"><a href="/">Home</a></nav>
      <div class="post-content">
        <p>#{String.duplicate("Real article prose. ", 20)}</p>
      </div>
      <div class="footer">Footer junk</div>
      """

      output = rendered(body)
      assert output =~ "Real article prose."
      refute output =~ "Footer junk"
      refute output =~ "Home"
    end

    test "folds a nested paragraph's text into its parent" do
      {_tree, _result, text} = extract_body(~s|<div class="post-content"><p>outer <p>inner</p></p></div>|)
      assert text =~ "outer"
    end
  end

  describe "lists" do
    test "renders items with markers" do
      body =
        ~s|<div class="post-content"><p>#{String.duplicate("lead ", 60)}</p><ul><li>alpha</li><li>beta</li></ul></div>|

      output = rendered(body)

      assert output =~ "- alpha"
      assert output =~ "- beta"
    end

    test "numbers ordered lists in markdown only" do
      body =
        ~s|<div class="post-content"><p>#{String.duplicate("lead ", 60)}</p><ol><li>first</li><li>second</li></ol></div>|

      assert rendered(body, include_formatting: true) =~ "1. first"
      assert rendered(body, include_formatting: true) =~ "2. second"
      # plain text uses dashes: bare digits would read as content
      assert rendered(body) =~ "- first"
    end

    test "indents a nested list" do
      body = """
      <div class="post-content"><p>#{String.duplicate("lead ", 60)}</p>
      <ul><li>outer<ul><li>inner</li></ul></li></ul></div>
      """

      assert rendered(body, include_formatting: true) =~ "  - inner"
    end
  end

  describe "headings" do
    test "renders heading levels in markdown" do
      body = ~s|<div class="post-content"><h2>Section</h2><p>#{String.duplicate("body ", 60)}</p></div>|
      assert rendered(body, include_formatting: true) =~ "## Section"
    end

    test "drops a trailing heading with nothing after it" do
      body = ~s|<div class="post-content"><p>#{String.duplicate("body ", 60)}</p><h2>Dangling</h2></div>|
      refute rendered(body) =~ "Dangling"
    end
  end

  describe "tables" do
    test "renders a table as GFM with a header separator" do
      body = """
      <div class="post-content"><p>#{String.duplicate("lead ", 60)}</p>
      <table><tr><th>Name</th><th>Qty</th></tr><tr><td>Apples</td><td>3</td></tr></table></div>
      """

      output = rendered(body, include_formatting: true)
      assert output =~ "| Name | Qty |"
      assert output =~ "|---|---|"
      assert output =~ "| Apples | 3 |"
    end

    test "materializes colspan so later rows stay aligned" do
      body = """
      <div class="post-content"><p>#{String.duplicate("lead ", 60)}</p>
      <table><tr><td colspan="2">wide</td></tr><tr><td>a</td><td>b</td></tr></table></div>
      """

      {tree, result, _text} = extract_body(body)
      table = Tree.find(tree, result, "table")
      widths = tree |> Tree.children(table) |> Enum.map(&Tree.child_count(tree, &1))

      assert widths == [2, 2]
    end

    test "materializes rowspan into placeholder cells" do
      body = """
      <div class="post-content"><p>#{String.duplicate("lead ", 60)}</p>
      <table><tr><td rowspan="2">tall</td><td>a</td></tr><tr><td>b</td></tr></table></div>
      """

      {tree, result, _text} = extract_body(body)
      table = Tree.find(tree, result, "table")
      widths = tree |> Tree.children(table) |> Enum.map(&Tree.child_count(tree, &1))

      assert widths == [2, 2]
    end

    test "emits a caption as a header row" do
      body = """
      <div class="post-content"><p>#{String.duplicate("lead ", 60)}</p>
      <table><caption>My Caption</caption><tr><td>a</td></tr></table></div>
      """

      assert rendered(body) =~ "My Caption"
    end

    test "escapes pipes so a cell cannot break the row" do
      body = """
      <div class="post-content"><p>#{String.duplicate("lead ", 60)}</p>
      <table><tr><td>a|b</td></tr></table></div>
      """

      assert rendered(body, include_formatting: true) =~ "a\\|b"
    end

    test "drops table content entirely when tables are excluded" do
      body =
        ~s|<div class="post-content"><p>#{String.duplicate("lead ", 60)}</p><table><tr><td>secret</td></tr></table></div>|

      refute rendered(body, include_tables: false) =~ "secret"
    end
  end

  describe "quotes and code" do
    test "keeps blockquote text" do
      body =
        ~s|<div class="post-content"><p>#{String.duplicate("lead ", 60)}</p><blockquote>quoted words</blockquote></div>|

      assert rendered(body) =~ "quoted words"
    end

    test "fences a multi-line code block in markdown" do
      body = """
      <div class="post-content"><p>#{String.duplicate("lead ", 60)}</p>
      <pre><code>def foo do
          :ok
      end</code></pre></div>
      """

      output = rendered(body, include_formatting: true)
      assert output =~ "```"
      assert output =~ "def foo do"
    end

    test "collapses a nested quote rather than emitting quote-in-quote" do
      body = """
      <div class="post-content"><p>#{String.duplicate("lead ", 60)}</p>
      <blockquote><blockquote>deep</blockquote></blockquote></div>
      """

      {tree, result, _text} = extract_body(body)
      quotes = Tree.find_all(tree, result, "quote")

      assert Enum.all?(quotes, &(Tree.find(tree, &1, "quote") == nil))
    end
  end

  describe "formatting" do
    test "renders emphasis as markdown" do
      body = ~s|<div class="post-content"><p>#{String.duplicate("lead ", 60)}<b>bold</b> and <i>italic</i></p></div>|
      output = rendered(body, include_formatting: true)

      assert output =~ "**bold**"
      assert output =~ "*italic*"
    end

    test "renders links with their targets" do
      body =
        ~s|<div class="post-content"><p>#{String.duplicate("lead ", 60)}<a href="https://x.test/p">here</a></p></div>|

      output = rendered(body, include_formatting: true, include_links: true)

      assert output =~ "[here](https://x.test/p)"
    end

    test "wraps a link target containing spaces in angle brackets" do
      body =
        ~s|<div class="post-content"><p>#{String.duplicate("lead ", 60)}<a href="https://x.test/a b">here</a></p></div>|

      assert rendered(body, include_formatting: true, include_links: true) =~ "(<https://x.test/a b>)"
    end
  end

  describe "images" do
    test "renders an image with alt text when images are requested" do
      body = """
      <div class="post-content"><p>#{String.duplicate("lead ", 60)}</p>
      <img src="https://x.test/a.png" alt="A picture"></div>
      """

      assert rendered(body, include_images: true, include_formatting: true) =~
               "![A picture](https://x.test/a.png)"
    end

    test "resolves a relative image source against the page URL" do
      body = ~s|<div class="post-content"><p>#{String.duplicate("lead ", 60)}</p><img src="/img/a.png" alt="x"></div>|

      assert rendered(body, include_images: true, include_formatting: true, url: "https://x.test/post") =~
               "https://x.test/img/a.png"
    end

    test "ignores images by default" do
      body = ~s|<div class="post-content"><p>#{String.duplicate("lead ", 60)}</p><img src="a.png" alt="nope"></div>|
      refute rendered(body, include_formatting: true) =~ "nope"
    end
  end

  describe "wild-text recovery" do
    test "recovers paragraphs when no content area is identifiable" do
      body = ~s|<section><p>#{String.duplicate("orphan prose ", 30)}</p></section>|
      assert rendered(body) =~ "orphan prose"
    end
  end

  describe "extract_comments/3" do
    test "captures a comment section and removes it from the tree" do
      body = """
      <div class="post-content"><p>#{String.duplicate("article ", 40)}</p></div>
      <div id="comments"><p>A reader comment</p></div>
      """

      {tree, root, options} = convert(body)
      {tree, comments, text, length} = MainExtractor.extract_comments(tree, root, options)

      assert text =~ "A reader comment"
      assert length > 0
      assert Tree.find(tree, root, "div") == nil or not (text(tree, root) =~ "A reader comment")
      assert comments != nil
    end

    test "returns nothing when there is no comment section" do
      {tree, root, options} = convert(~s|<div class="post-content"><p>just an article</p></div>|)
      {_tree, _comments, text, length} = MainExtractor.extract_comments(tree, root, options)

      assert text == ""
      assert length == 0
    end
  end

  describe "duplicate suppression" do
    test "drops a long element repeating the one before it" do
      repeated = String.duplicate("this exact sentence repeats verbatim ", 3)

      body =
        ~s|<div class="post-content"><p>#{repeated}</p><p>#{repeated}</p><p>#{String.duplicate("other ", 40)}</p></div>|

      {tree, result, _text} = extract_body(body)
      texts = tree |> Tree.children(result) |> Enum.map(&MainExtractor.elem_text(tree, &1))

      assert length(Enum.filter(texts, &(&1 == String.trim(repeated)))) == 1
    end
  end
end
