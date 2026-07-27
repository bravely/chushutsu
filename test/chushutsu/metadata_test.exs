defmodule Chushutsu.MetadataTest do
  use ExUnit.Case, async: true

  alias Chushutsu.{Metadata, Options, Tree}

  defp meta(head, body \\ "<p>text</p>", opts \\ []) do
    tree = Tree.parse("<html><head>#{head}</head><body>#{body}</body></html>")
    Metadata.extract(tree, Tree.root(tree), Options.new(opts))
  end

  describe "OpenGraph" do
    test "reads the standard properties" do
      document =
        meta("""
        <meta property="og:title" content="OG Title">
        <meta property="og:description" content="OG description">
        <meta property="og:site_name" content="OG Site">
        <meta property="og:image" content="https://x.test/i.png">
        <meta property="og:type" content="article">
        <meta property="og:url" content="https://x.test/post">
        """)

      assert document.title == "OG Title"
      assert document.description == "OG description"
      assert document.sitename == "OG Site"
      assert document.image == "https://x.test/i.png"
      assert document.pagetype == "article"
      assert document.url == "https://x.test/post"
    end

    test "ignores an og:url that is not a valid absolute URL" do
      assert meta(~s|<meta property="og:url" content="not a url">|).url == nil
    end
  end

  describe "meta tags" do
    test "reads author, description, publisher and keywords" do
      document =
        meta("""
        <meta name="author" content="Ada Lovelace">
        <meta name="description" content="A description">
        <meta name="publisher" content="The Publisher">
        <meta name="keywords" content="one, two">
        """)

      assert document.author == "Ada Lovelace"
      assert document.description == "A description"
      assert document.sitename == "The Publisher"
      assert document.tags == ["one, two"]
    end

    test "collects article:tag properties" do
      document = meta(~s|<meta property="article:tag" content="alpha"><meta property="article:tag" content="beta">|)
      assert document.tags == ["alpha", "beta"]
    end

    test "discards a single-word author so the markup heuristics can try" do
      assert meta(~s|<meta name="author" content="Anonymous">|).author == nil
    end

    test "strips markup out of a content attribute" do
      assert meta(~s|<meta name="description" content="&lt;b&gt;bold&lt;/b&gt; text">|).description =~ "bold"
    end
  end

  describe "JSON-LD" do
    test "reads headline, author, publisher and date" do
      json = """
      {"@type":"NewsArticle","headline":"JSON Headline",
       "author":{"@type":"Person","name":"Grace Hopper"},
       "publisher":{"@type":"Organization","name":"JSON Publisher"},
       "datePublished":"2024-03-05T10:00:00Z"}
      """

      document = meta(~s|<script type="application/ld+json">#{json}</script>|)

      assert document.title == "JSON Headline"
      assert document.author == "Grace Hopper"
      assert document.sitename == "JSON Publisher"
      assert document.date == "2024-03-05"
    end

    test "handles an @graph wrapper" do
      json = ~s|{"@graph":[{"@type":"Article","headline":"Graph Headline"}]}|
      assert meta(~s|<script type="application/ld+json">#{json}</script>|).title == "Graph Headline"
    end

    test "joins several authors" do
      json = ~s|{"@type":"Article","author":[{"name":"A One"},{"name":"B Two"}]}|
      assert meta(~s|<script type="application/ld+json">#{json}</script>|).author == "A One; B Two"
    end

    test "ignores malformed JSON-LD" do
      document = meta(~s|<script type="application/ld+json">{oops</script><title>Fallback Title</title>|)
      assert document.title == "Fallback Title"
    end
  end

  describe "title" do
    test "a lone h1 wins" do
      assert meta("", "<h1>The Only Heading</h1>").title == "The Only Heading"
    end

    test "falls back to a title-classed heading" do
      body = ~s|<h1>One</h1><h1>Two</h1><h2 class="entry-title">Entry Title</h2>|
      assert meta("", body).title == "Entry Title"
    end

    test "splits a document title on its separator, taking the headline half" do
      assert meta("<title>Real Headline | example.com</title>", "<div>x</div>").title == "Real Headline"
    end

    test "takes a site name from the half containing a dot" do
      assert meta("<title>Real Headline | example.com</title>", "<div>x</div>").sitename == "example.com"
    end
  end

  describe "author" do
    test "reads a byline from the markup" do
      assert meta("", ~s|<p class="byline">Jane Roe</p>|).author == "Jane Roe"
    end

    test "strips a leading by-word" do
      assert meta("", ~s|<span class="author">By Jane Roe</span>|).author == "Jane Roe"
    end

    test "ignores bylines inside comment sections" do
      body = ~s|<div id="comments"><span class="author">Commenter Name</span></div>|
      assert meta("", body).author == nil
    end

    test "applies the blacklist" do
      document = meta(~s|<meta name="author" content="Jane Roe">|, "<p>x</p>", author_blacklist: ["jane roe"])
      assert document.author == nil
    end
  end

  describe "url and hostname" do
    test "reads the canonical link and derives the hostname" do
      document = meta(~s|<link rel="canonical" href="https://site.test/a/b">|)

      assert document.url == "https://site.test/a/b"
      assert document.hostname == "site.test"
    end

    test "falls back to the supplied url" do
      assert meta("", "<p>x</p>", url: "https://given.test/p").url == "https://given.test/p"
    end

    test "og:url outranks the canonical link" do
      head = ~s|<link rel="canonical" href="/path"><meta property="og:url" content="https://site.test/other">|
      assert meta(head).url == "https://site.test/other"
    end

    test "resolves a relative canonical against any OpenGraph URL on the page" do
      # no og:url to take precedence, so the canonical is used and its missing
      # origin is borrowed from another absolute og:/twitter: value
      head = ~s|<link rel="canonical" href="/path"><meta property="og:image" content="https://site.test/i.png">|
      assert meta(head).url == "https://site.test/path"
    end
  end

  describe "date" do
    test "reads a published-time meta tag" do
      assert meta(~s|<meta property="article:published_time" content="2023-11-02T08:00:00Z">|).date == "2023-11-02"
    end

    test "reads a time element's datetime" do
      assert meta("", ~s|<time datetime="2022-05-06">then</time>|).date == "2022-05-06"
    end

    test "falls back to a date in the URL" do
      assert meta("", "<p>x</p>", url: "https://site.test/2021/07/09/slug").date == "2021-07-09"
    end

    test "rejects an impossible date" do
      assert meta(~s|<meta name="date" content="2023-13-45">|).date == nil
    end
  end

  describe "license" do
    test "reads a Creative Commons license from a rel=license href" do
      body = ~s|<a rel="license" href="https://creativecommons.org/licenses/by-sa/4.0/">CC</a>|
      assert meta("", body).license == "CC BY-SA 4.0"
    end

    test "finds a license link in the footer" do
      body = ~s|<footer><a href="https://creativecommons.org/licenses/by-nc/3.0/">terms</a></footer>|
      assert meta("", body).license == "CC BY-NC 3.0"
    end
  end

  describe "site name" do
    test "title-cases a bare name and strips a Twitter handle" do
      assert meta(~s|<meta name="twitter:site" content="@examplesite">|).sitename == "Examplesite"
    end

    test "derives one from the URL as a last resort" do
      assert meta("", "<p>x</p>", url: "https://www.example.test/a").sitename == "example.test"
    end
  end

  describe "categories and tags" do
    test "reads category links from a post-meta block" do
      body = ~s|<div class="post-meta"><a href="/category/news/">News</a></div>|
      assert meta("", body).categories == ["News"]
    end

    test "falls back to an article:section meta tag" do
      assert meta(~s|<meta property="article:section" content="Opinion">|).categories == ["Opinion"]
    end

    test "reads tag links" do
      body = ~s|<div class="tags"><a href="/tag/elixir/">Elixir</a></div>|
      assert meta("", body).tags == ["Elixir"]
    end
  end
end
