defmodule ChushutsuTest do
  use ExUnit.Case, async: true

  doctest Chushutsu

  @article """
  <html>
  <head>
    <title>How Extraction Works - Example News</title>
    <meta property="og:title" content="How Extraction Works">
    <meta name="author" content="Ada Lovelace">
    <meta property="article:published_time" content="2024-02-01T09:00:00Z">
    <link rel="canonical" href="https://news.test/how-extraction-works">
  </head>
  <body>
    <nav class="navbar"><a href="/">Home</a><a href="/tech">Tech</a></nav>
    <div class="post-content">
      <h1>How Extraction Works</h1>
      <p>Extraction begins by locating the region of the page that holds the article,
         which is usually signposted by conventional class and id vocabulary.</p>
      <p>When that fails, generic algorithms take over and score the page by the shape
         of its text rather than the names its author gave to things.</p>
      <ul><li>Locate</li><li>Prune</li><li>Serialize</li></ul>
    </div>
    <div id="comments"><p>Great write-up, thanks for sharing this one.</p></div>
    <div class="footer">© 2024 Example News</div>
  </body>
  </html>
  """

  describe "extract/2" do
    test "returns the article and drops the chrome" do
      assert {:ok, text} = Chushutsu.extract(@article)

      assert text =~ "Extraction begins by locating"
      assert text =~ "generic algorithms take over"
      refute text =~ "Example News"
      refute text =~ "Home"
    end

    test "includes comments by default and omits them on request" do
      {:ok, with_comments} = Chushutsu.extract(@article)
      {:ok, without} = Chushutsu.extract(@article, include_comments: false)

      assert with_comments =~ "Great write-up"
      refute without =~ "Great write-up"
    end

    test "renders markdown when asked" do
      assert {:ok, text} = Chushutsu.extract(@article, output_format: :markdown)

      assert text =~ "# How Extraction Works"
      assert text =~ "- Locate"
    end

    test "fast mode still extracts the article" do
      assert {:ok, text} = Chushutsu.extract(@article, fast: true)
      assert text =~ "Extraction begins by locating"
    end

    test "precision and recall modes both return the article" do
      assert {:ok, precise} = Chushutsu.extract(@article, favor_precision: true)
      assert {:ok, recalled} = Chushutsu.extract(@article, favor_recall: true)

      assert precise =~ "Extraction begins"
      assert recalled =~ "Extraction begins"
    end

    test "rejects input that is not an HTML document" do
      assert {:error, :empty_tree} = Chushutsu.extract("")
      assert {:error, :empty_tree} = Chushutsu.extract("not markup at all")
    end

    test "accepts a document that carries real markup" do
      html = "<div class='post-content'><p>#{String.duplicate("real prose ", 40)}</p></div>"
      assert {:ok, text} = Chushutsu.extract(html)
      assert text =~ "real prose"
    end

    test "reports unsupported input for a non-binary" do
      assert {:error, :unsupported_input} = Chushutsu.extract(:not_html)
    end

    test "accepts an already-parsed tree" do
      tree = Chushutsu.Tree.parse(@article)
      assert {:ok, text} = Chushutsu.extract(tree)
      assert text =~ "Extraction begins"
    end

    test "a page with no article yields too_short" do
      assert {:error, :too_short} = Chushutsu.extract("<html><body><div></div></body></html>")
    end
  end

  describe "extract!/2" do
    test "returns the text directly, or nil on failure" do
      assert Chushutsu.extract!(@article) =~ "Extraction begins"
      assert Chushutsu.extract!("") == nil
    end
  end

  describe "extract_with_metadata/2" do
    test "returns text alongside the metadata fields" do
      assert {:ok, document} = Chushutsu.extract_with_metadata(@article)

      assert document.title == "How Extraction Works"
      assert document.author == "Ada Lovelace"
      assert document.date == "2024-02-01"
      assert document.url == "https://news.test/how-extraction-works"
      assert document.hostname == "news.test"
      assert document.text =~ "Extraction begins"
      assert is_binary(document.fingerprint)
    end
  end

  describe "output formats" do
    test "json carries the text and parses back" do
      assert {:ok, json} = Chushutsu.extract(@article, output_format: :json)
      assert %{"text" => text} = Jason.decode!(json)
      assert text =~ "Extraction begins"
    end

    test "xml wraps body and comments under a doc element" do
      assert {:ok, xml} = Chushutsu.extract(@article, output_format: :xml, with_metadata: true)

      assert xml =~ "<doc"
      assert xml =~ "<main>"
      assert xml =~ "<comments>"
      assert xml =~ "Extraction begins"
    end

    test "xmltei emits a TEI header" do
      assert {:ok, tei} = Chushutsu.extract(@article, output_format: :xmltei)

      assert tei =~ ~s|<TEI xmlns="http://www.tei-c.org/ns/1.0">|
      assert tei =~ "<teiHeader>"
      assert tei =~ "<titleStmt>"
    end

    test "html maps the internal vocabulary back onto HTML tags" do
      assert {:ok, html} = Chushutsu.extract(@article, output_format: :html)

      assert html =~ "<body>"
      assert html =~ "<ul>"
      assert html =~ "<li>Locate</li>"
    end

    test "csv emits one delimited row" do
      assert {:ok, csv} = Chushutsu.extract(@article, output_format: :csv, with_metadata: true)

      assert String.ends_with?(csv, "\r\n")
      assert csv =~ "news.test"
    end

    test "txt with metadata emits a YAML header" do
      assert {:ok, text} = Chushutsu.extract(@article, with_metadata: true)

      assert String.starts_with?(text, "---\n")
      assert text =~ "title: How Extraction Works"
      assert text =~ "author: Ada Lovelace"
    end

    test "an unsupported format is rejected up front" do
      assert_raise ArgumentError, ~r/unsupported output format/, fn ->
        Chushutsu.extract(@article, output_format: :pdf)
      end
    end
  end

  describe "metadata/2" do
    test "extracts metadata without running content extraction" do
      assert {:ok, document} = Chushutsu.metadata(@article)

      assert document.title == "How Extraction Works"
      assert document.text == nil
    end
  end

  describe "baseline/1 and html_to_text/2" do
    test "baseline finds the article without the content-area rules" do
      assert {:ok, text} = Chushutsu.baseline(@article)
      assert text =~ "Extraction begins"
    end

    test "html_to_text flattens the whole page" do
      assert {:ok, text} = Chushutsu.html_to_text(@article)

      assert text =~ "Extraction begins"
      # nav survives: this makes no attempt to find the content
      assert text =~ "Home"
    end
  end

  describe "bare_extraction/2" do
    test "returns the document with its tree available for walking" do
      assert {:ok, document} = Chushutsu.bare_extraction(@article)

      alias Chushutsu.Tree
      assert Tree.tag(document.tree, document.body) == "body"
      assert length(Tree.children(document.tree, document.body)) > 1
    end
  end

  describe "target language" do
    test "discards a document whose declared language does not match" do
      html = String.replace(@article, "<head>", ~s|<head><meta http-equiv="content-language" content="de">|)
      assert {:error, :wrong_language} = Chushutsu.extract(html, target_language: "en", fast: true)
    end

    test "keeps a document whose declared language matches" do
      html = String.replace(@article, "<head>", ~s|<head><meta http-equiv="content-language" content="en">|)
      assert {:ok, _text} = Chushutsu.extract(html, target_language: "en", fast: true)
    end
  end

  describe "robustness" do
    test "survives deeply nested markup without blowing the stack" do
      nested = Enum.reduce(1..400, "<p>deep content here</p>", fn _i, acc -> "<div>#{acc}</div>" end)
      assert {:ok, _text} = Chushutsu.extract("<html><body>#{nested}</body></html>")
    end

    test "handles unclosed and mismatched tags" do
      html = "<html><body><div class='post-content'><p>text that never closes properly"
      assert {:ok, text} = Chushutsu.extract(html)
      assert text =~ "never closes"
    end

    test "strips control characters that would break serialization" do
      html =
        "<html><body><div class='post-content'><p>a\x00b\x08c#{String.duplicate(" word", 60)}</p></div></body></html>"

      assert {:ok, text} = Chushutsu.extract(html)
      assert text =~ "abc"
    end
  end
end
