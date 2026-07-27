defmodule Chushutsu.SelectorsTest do
  use ExUnit.Case, async: true

  alias Chushutsu.{Selectors, Tree}

  defp parse(body), do: Tree.parse("<html><body>#{body}</body></html>")

  defp first_content(body) do
    tree = parse(body)

    Selectors.content()
    |> Enum.find_value(fn rule -> Selectors.select_first(tree, Tree.root(tree), rule) end)
    |> case do
      nil -> nil
      id -> {Tree.tag(tree, id), Tree.attr(tree, id, "class") || Tree.attr(tree, id, "id")}
    end
  end

  defp discarded(rules, body) do
    tree = parse(body)

    Selectors.select_all(tree, Tree.root(tree), rules)
    |> Enum.map(&(Tree.attr(tree, &1, "id") || Tree.attr(tree, &1, "class")))
    |> Enum.uniq()
  end

  describe "content/0" do
    test "rule 1 matches article-content classes" do
      assert first_content(~s|<div class="post-content">x</div>|) == {"div", "post-content"}
      assert first_content(~s|<section class="entry">x</section>|) == {"section", "entry"}
      assert first_content(~s|<div itemprop="articleBody">x</div>|) == {"div", nil}
    end

    test "rule 1 outranks a later <article>" do
      body = ~s|<div class="post-body">a</div><article>b</article>|
      assert first_content(body) == {"div", "post-body"}
    end

    test "rule 2 falls back to the first article element" do
      assert first_content(~s|<article>x</article><article>y</article>|) == {"article", nil}
    end

    test "rule 4 folds only the letters translate() lists" do
      assert first_content(~s|<div class="Main-Content">x</div>|) == {"div", "Main-Content"}
      # translate(@class,'CM','cm') leaves A, I and N alone
      assert first_content(~s|<div class="MAIN-CONTENT">x</div>|) == nil
    end

    test "rule 5 takes whichever of <main> and a main-prefixed block comes first" do
      assert first_content(~s|<div id="mainbar">x</div><main>y</main>|) == {"div", "mainbar"}
      assert first_content(~s|<main>y</main><div id="mainbar">x</div>|) == {"main", nil}
    end

    test "returns nil when nothing matches" do
      assert first_content(~s|<div class="nothing">x</div>|) == nil
    end
  end

  describe "overall_discard/0" do
    test "drops share, nav and footer blocks" do
      body = ~s|<div id="share">a</div><div class="navbar">b</div><p class="footer">c</p>|
      assert discarded(Selectors.overall_discard(), body) == ["share", "navbar", "footer"]
    end

    test "hidden and aria-hidden elements go, on any tag" do
      body = ~s|<span id="hidden-x">a</span><h2 aria-hidden="true">b</h2>|
      assert discarded(Selectors.overall_discard(), body) == ["hidden-x", nil]
    end

    test "the cookie token is tested on the source-first attribute only" do
      # class comes first in source order, so @id|@class resolves to the class
      assert discarded(Selectors.overall_discard(), ~s|<div class="x" id="cookie-bar">a</div>|) == []
      assert discarded(Selectors.overall_discard(), ~s|<div id="cookie-bar" class="x">a</div>|) == ["cookie-bar"]
    end

    test "leaves ordinary content alone" do
      assert discarded(Selectors.overall_discard(), ~s|<p class="lede">a</p>|) == []
    end
  end

  describe "precision_discard/0" do
    test "matches link as a whole class token, not a substring" do
      assert discarded(Selectors.precision_discard(), ~s|<p class="link">a</p>|) == ["link"]
      assert discarded(Selectors.precision_discard(), ~s|<p class="a link b">a</p>|) == ["a link b"]
      assert discarded(Selectors.precision_discard(), ~s|<p class="permalink">a</p>|) == []
    end

    test "drops header elements" do
      assert discarded(Selectors.precision_discard(), ~s|<header id="h">a</header>|) == ["h"]
    end
  end

  describe "comments/0" do
    test "finds a comment list container" do
      tree = parse(~s|<div id="comments-list">a</div>|)

      found =
        Selectors.comments()
        |> Enum.find_value(&Selectors.select_first(tree, Tree.root(tree), &1))

      assert Tree.attr(tree, found, "id") == "comments-list"
    end
  end

  describe "teaser_discard/0" do
    test "folds only T when matching teaser" do
      assert discarded(Selectors.teaser_discard(), ~s|<div class="Teaser">a</div>|) == ["Teaser"]
      assert discarded(Selectors.teaser_discard(), ~s|<div class="TEASER">a</div>|) == []
    end
  end
end
