defmodule Chushutsu.HtmlProcessingTest do
  use ExUnit.Case, async: true

  import Chushutsu.TreeHelpers

  alias Chushutsu.{HtmlProcessing, Selectors, Tree}

  describe "tree_cleaning/3" do
    test "deletes chrome and unwraps presentational tags" do
      {tree, root} = parse(~s|<nav>menu</nav><p>keep <img src="a.png"> <small>this</small></p><script>x</script>|)
      {tree, root} = HtmlProcessing.tree_cleaning(tree, root, options())

      assert Tree.find(tree, root, "nav") == nil
      assert Tree.find(tree, root, "script") == nil
      # small and img are stripped, but their text survives
      assert Tree.find(tree, root, "small") == nil
      assert text(tree, root) =~ "keep"
      assert text(tree, root) =~ "this"
    end

    test "keeps <img> and its wrappers when images are requested" do
      {tree, root} = parse(~s|<figure><img src="a.png"></figure>|)
      {tree, root} = HtmlProcessing.tree_cleaning(tree, root, options(include_images: true))

      assert Tree.find(tree, root, "img") != nil
      assert Tree.find(tree, root, "figure") != nil
    end

    test "drops tables when they are excluded" do
      {tree, root} = parse(~s|<table><tr><td>cell</td></tr></table><p>text</p>|)
      {tree, root} = HtmlProcessing.tree_cleaning(tree, root, options(include_tables: false))

      assert Tree.find(tree, root, "table") == nil
      assert text(tree, root) == "text"
    end

    test "demotes a figure wrapping a table so the table survives" do
      {tree, root} = parse(~s|<figure><table><tr><td>data</td></tr></table></figure>|)
      {tree, root} = HtmlProcessing.tree_cleaning(tree, root, options())

      assert Tree.find(tree, root, "table") != nil
    end

    test "demotes ARIA layout tables" do
      {tree, root} = parse(~s|<table role="presentation"><tr><td>x</td></tr></table>|)
      {tree, root} = HtmlProcessing.tree_cleaning(tree, root, options())

      assert Tree.find(tree, root, "table") == nil
      assert Tree.find(tree, root, "div") != nil
    end
  end

  describe "prune_html/3" do
    test "removes empty elements but keeps their tail" do
      {tree, root} = parse(~s|<div>a<span></span>b</div>|)
      div = Tree.find(tree, root, "div")

      tree = HtmlProcessing.prune_html(tree, root, :balanced)

      assert Tree.find(tree, root, "span") == nil
      assert Tree.text_content(tree, div) == "ab"
    end

    test "drops the tail too when favouring precision" do
      {tree, root} = parse(~s|<div>a<span></span>b</div>|)
      div = Tree.find(tree, root, "div")

      tree = HtmlProcessing.prune_html(tree, root, :precision)

      assert Tree.text_content(tree, div) == "a"
    end

    test "leaves an element holding only whitespace alone" do
      {tree, root} = parse(~s|<div><span> </span></div>|)
      tree = HtmlProcessing.prune_html(tree, root, :balanced)

      assert Tree.find(tree, root, "span") != nil
    end
  end

  describe "prune_unwanted_nodes/4" do
    test "removes matching sections" do
      {tree, root} = parse(~s|<p>keep</p><div class="navbar">drop</div>|)
      {tree, root} = HtmlProcessing.prune_unwanted_nodes(tree, root, Selectors.overall_discard())

      assert text(tree, root) == "keep"
    end

    test "with_backup reverts a prune that removed nearly everything" do
      # every element matches, so pruning would leave almost no text behind
      body = ~s|<div class="widget">#{String.duplicate("content ", 50)}</div><p>x</p>|
      {tree, root} = parse(body)

      {tree, result_root} =
        HtmlProcessing.prune_unwanted_nodes(tree, root, Selectors.overall_discard(), with_backup: true)

      assert text(tree, result_root) =~ "content"
    end

    test "with_backup keeps the prune when enough text remains" do
      body = ~s|<div class="widget">ad</div><p>#{String.duplicate("real content ", 50)}</p>|
      {tree, root} = parse(body)

      {tree, result_root} =
        HtmlProcessing.prune_unwanted_nodes(tree, root, Selectors.overall_discard(), with_backup: true)

      refute text(tree, result_root) =~ "ad"
    end
  end

  describe "link_density_test/4" do
    test "a short element that is mostly links is boilerplate" do
      {tree, root} = parse(~s|<p><ref>one</ref> <ref>two</ref> <ref>three</ref></p>|)
      p = Tree.find(tree, root, "p")
      content = Tree.text_content(tree, p)

      assert {true, _texts} = HtmlProcessing.link_density_test(tree, p, content)
    end

    test "prose with one link is kept" do
      long = String.duplicate("sentence of real prose ", 10)
      {tree, root} = parse(~s|<p>#{long}<ref>a link</ref></p>|)
      p = Tree.find(tree, root, "p")

      assert {false, _texts} = HtmlProcessing.link_density_test(tree, p, Tree.text_content(tree, p))
    end

    test "an element with no links is never boilerplate" do
      {tree, root} = parse(~s|<p>plain text</p>|)
      p = Tree.find(tree, root, "p")

      assert HtmlProcessing.link_density_test(tree, p, "plain text") == {false, []}
    end

    test "an image container is spared regardless of link density" do
      {tree, root} = parse(~s|<div><ref>x</ref><graphic src="a.png"/></div>|)
      div = Tree.find(tree, root, "div")

      assert HtmlProcessing.link_density_test(tree, div, "x") == {false, []}
    end

    test "a large near-total link farm is caught above the size gate" do
      links = Enum.map_join(1..8, "", fn i -> "<ref>#{String.duplicate("link#{i} ", 4)}</ref>" end)
      {tree, root} = parse(~s|<div>#{links}</div>|)
      div = Tree.find(tree, root, "div")

      assert {true, _texts} = HtmlProcessing.link_density_test(tree, div, Tree.text_content(tree, div))
    end
  end

  describe "link_density_test_tables/2" do
    test "ignores short tables" do
      {tree, root} = parse(~s|<table><ref>a</ref></table>|)
      refute HtmlProcessing.link_density_test_tables(tree, Tree.find(tree, root, "table"))
    end

    test "flags a long table that is mostly link text" do
      # links must sit inside cells: the HTML5 parser foster-parents stray
      # content out of a <table>, which would leave nothing to measure
      rows = Enum.map_join(1..20, "", fn i -> "<tr><td><ref>a fairly long link label #{i}</ref></td></tr>" end)
      {tree, root} = parse(~s|<table>#{rows}</table>|)

      assert HtmlProcessing.link_density_test_tables(tree, Tree.find(tree, root, "table"))
    end
  end

  describe "delete_by_link_density/4" do
    test "keeps a paragraph that holds a list item's content" do
      {tree, root} = parse(~s|<list><item><p><ref>a</ref></p></item></list>|)
      tree = HtmlProcessing.delete_by_link_density(tree, root, "p")

      assert Tree.find(tree, root, "p") != nil
    end
  end

  describe "convert_tags/4" do
    test "maps HTML structure onto the internal vocabulary" do
      {tree, root} = parse(~s|<h2>Title</h2><ul><li>a</li></ul><blockquote>q</blockquote><br>|)
      tree = HtmlProcessing.convert_tags(tree, root, options())

      assert Tree.find(tree, root, "head") != nil
      assert Tree.attr(tree, Tree.find(tree, root, "head"), "rend") == "h2"
      assert Tree.find(tree, root, "list") != nil
      assert Tree.find(tree, root, "item") != nil
      assert Tree.find(tree, root, "quote") != nil
      assert Tree.find(tree, root, "lb") != nil
    end

    test "renames anchors inside content blocks and strips the rest" do
      {tree, root} = parse(~s|<p><a href="/x">inside</a></p><a href="/y">outside</a>|)
      tree = HtmlProcessing.convert_tags(tree, root, options())

      assert length(Tree.find_all(tree, root, "ref")) == 1
      assert Tree.find(tree, root, "a") == nil
      # the stray anchor is unwrapped, not deleted
      assert text(tree, root) =~ "outside"
    end

    test "keeps link targets and absolutizes them when links are requested" do
      {tree, root} = parse(~s|<p><a href="/x">link</a></p>|)
      tree = HtmlProcessing.convert_tags(tree, root, options(include_links: true), "https://site.test/a/b")

      ref = Tree.find(tree, root, "ref")
      assert Tree.attr(tree, ref, "target") == "https://site.test/x"
    end

    test "collapses formatting tags into hi when formatting is kept" do
      {tree, root} = parse(~s|<p><b>bold</b> and <em>italic</em></p>|)
      tree = HtmlProcessing.convert_tags(tree, root, options(include_formatting: true))

      rends = tree |> Tree.find_all(root, "hi") |> Enum.map(&Tree.attr(tree, &1, "rend"))
      assert rends == ["#b", "#i"]
    end

    test "strips formatting tags otherwise, keeping the text" do
      {tree, root} = parse(~s|<p><b>bold</b> text</p>|)
      tree = HtmlProcessing.convert_tags(tree, root, options())

      assert Tree.find(tree, root, "hi") == nil
      assert text(tree, root) =~ "bold"
    end

    test "treats a syntax-highlighted pre as code" do
      {tree, root} = parse(~s|<pre><span class="hljs-keyword">def</span></pre>|)
      tree = HtmlProcessing.convert_tags(tree, root, options())

      assert Tree.find(tree, root, "code") != nil
    end

    test "treats a plain pre as a quote" do
      {tree, root} = parse(~s|<pre>just some preformatted prose</pre>|)
      tree = HtmlProcessing.convert_tags(tree, root, options())

      assert Tree.find(tree, root, "quote") != nil
      assert Tree.find(tree, root, "code") == nil
    end

    test "numbers dd/dt pairs so they stay associated" do
      {tree, root} = parse(~s|<dl><dt>term</dt><dd>definition</dd><dt>second</dt></dl>|)
      tree = HtmlProcessing.convert_tags(tree, root, options())

      rends = tree |> Tree.find_all(root, "item") |> Enum.map(&Tree.attr(tree, &1, "rend"))
      assert rends == ["dt-1", "dd-1", "dt-2"]
    end

    test "promotes Yoast FAQ questions to headings" do
      {tree, root} = parse(~s|<strong class="schema-faq-question">Q?</strong>|)
      tree = HtmlProcessing.convert_tags(tree, root, options())

      head = Tree.find(tree, root, "head")
      assert Tree.attr(tree, head, "rend") == "h3"
    end

    test "lifts an image out of the link wrapping it" do
      {tree, root} = parse(~s|<p><a href="/x"><img src="a.png"></a></p>|)
      tree = HtmlProcessing.convert_tags(tree, root, options(include_images: true, include_links: true))

      graphic = Tree.find(tree, root, "graphic")
      assert Tree.tag(tree, Tree.parent(tree, graphic)) != "ref"
    end
  end

  describe "handle_textnode/4" do
    test "borrows the tail when the element has no text of its own" do
      {tree, root} = parse(~s|<div><span></span>tail text</div>|)
      span = Tree.find(tree, root, "span")

      {tree, result} = HtmlProcessing.handle_textnode(tree, span, options())

      assert result == span
      assert Tree.text(tree, span) == "tail text"
    end

    test "keeps text that the share filter would reject, which only guards tails" do
      # the filter is applied to elements with no text of their own; an element
      # whose own text reads "Facebook" is left for process_node/3 to reject
      {tree, root} = parse(~s|<p>Facebook</p>|)
      p = Tree.find(tree, root, "p")

      assert {_tree, ^p} = HtmlProcessing.handle_textnode(tree, p, options())
    end

    test "rejects an element with nothing in it" do
      {tree, root} = parse(~s|<div><span></span></div>|)
      span = Tree.find(tree, root, "span")

      assert {_tree, nil} = HtmlProcessing.handle_textnode(tree, span, options())
    end

    test "preserves internal spacing when asked" do
      {tree, root} = parse(~s|<p>  a   b  </p>|)
      p = Tree.find(tree, root, "p")

      {tree, result} = HtmlProcessing.handle_textnode(tree, p, options(), preserve_spaces: true)
      assert Tree.text(tree, result) == "  a   b  "

      {tree, root} = parse(~s|<p>  a   b  </p>|)
      p = Tree.find(tree, root, "p")
      {tree, result} = HtmlProcessing.handle_textnode(tree, p, options())
      assert Tree.text(tree, result) == "a b"
    end
  end

  describe "process_node/3" do
    test "rejects share boilerplate" do
      {tree, root} = parse(~s|<p>Facebook</p>|)
      p = Tree.find(tree, root, "p")

      assert {_tree, nil} = HtmlProcessing.process_node(tree, p, options())
    end

    test "promotes a lone tail into the element's text" do
      {tree, root} = parse(~s|<div><span></span>only a tail</div>|)
      span = Tree.find(tree, root, "span")

      {tree, result} = HtmlProcessing.process_node(tree, span, options())

      assert Tree.text(tree, result) == "only a tail"
      assert Tree.tail(tree, result) == nil
    end
  end
end
