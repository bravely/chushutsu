defmodule Chushutsu.ExternalTest do
  use ExUnit.Case, async: true

  import Chushutsu.TreeHelpers

  alias Chushutsu.External.{JusText, Readability}
  alias Chushutsu.{Text, Tree}

  describe "Readability.summary/3" do
    test "picks the container holding the prose" do
      body = """
      <div id="sidebar"><a href="/a">Link</a><a href="/b">Link</a></div>
      <div id="main"><p>#{String.duplicate("Real, comma-bearing prose. ", 20)}</p></div>
      """

      {tree, root} = parse(body)
      {tree, article} = Readability.summary(tree, root)

      assert article != nil
      assert text(tree, article) =~ "comma-bearing prose"
    end

    test "drops sections whose class marks them as chrome" do
      body = """
      <div id="content"><p>#{String.duplicate("The article body, with commas. ", 20)}</p></div>
      <div class="comment"><p>#{String.duplicate("A comment thread, chattering. ", 10)}</p></div>
      """

      {tree, root} = parse(body)
      {tree, article} = Readability.summary(tree, root)

      assert text(tree, article) =~ "The article body"
      refute text(tree, article) =~ "chattering"
    end

    test "leaves the caller's tree untouched" do
      {tree, root} = parse(~s|<div id="main"><p>#{String.duplicate("prose, prose. ", 20)}</p></div>|)
      before = text(tree, root)

      {_tree, _article} = Readability.summary(tree, root)

      assert text(tree, root) == before
    end

    test "returns nil rather than raising on an empty document" do
      {tree, root} = parse("")
      assert {_tree, _result} = Readability.summary(tree, root)
    end
  end

  describe "JusText.extract/3" do
    test "keeps long stopword-rich prose and drops navigation" do
      prose =
        "This is a fairly long paragraph of ordinary prose that should be kept " <>
          "because it is long enough and it contains a great many of the common " <>
          "words that the classifier uses to tell content from boilerplate."

      body = """
      <div><a href="/a">Home</a> <a href="/b">About</a> <a href="/c">Contact</a></div>
      <p>#{prose}</p>
      """

      {tree, root} = parse(body)
      kept = JusText.extract(tree, root, "en")

      assert Enum.any?(kept, &(&1 =~ "ordinary prose"))
      refute Enum.any?(kept, &(&1 =~ "Contact"))
    end

    test "discards a paragraph that is mostly links" do
      {tree, root} = parse(~s|<p><a href="/a">#{String.duplicate("link text ", 20)}</a></p>|)

      assert JusText.extract(tree, root, "en") == []
    end

    test "discards a copyright line" do
      {tree, root} = parse("<p>© 2024 Example Corporation, all rights reserved worldwide indeed</p>")

      refute Enum.any?(JusText.extract(tree, root, "en"), &(&1 =~ "Example Corporation"))
    end

    test "works without a language, using the combined stoplist" do
      prose = String.duplicate("Dies ist ein langer Absatz mit vielen gewöhnlichen Wörtern. ", 4)
      {tree, root} = parse("<p>#{prose}</p>")

      assert JusText.extract(tree, root, nil) != []
    end
  end

  describe "JusText.Stoplists" do
    alias Chushutsu.External.JusText.Stoplists

    test "resolves a language code to its list" do
      english = Stoplists.for_language("en")

      assert MapSet.member?(english, "the")
      refute MapSet.member?(english, "gewöhnlichen")
    end

    test "falls back to the combined list for an unknown code" do
      assert Stoplists.for_language("xx") == Stoplists.combined()
      assert Stoplists.for_language(nil) == Stoplists.combined()
    end

    test "the combined list spans many languages" do
      combined = Stoplists.combined()

      assert MapSet.member?(combined, "the")
      assert MapSet.member?(combined, "und")
      assert MapSet.member?(combined, "les")
      assert MapSet.size(combined) > 100_000
    end
  end

  describe "compare_extraction/7" do
    alias Chushutsu.{External, HtmlProcessing, Options}

    test "adopts readability when the rule-based result is empty" do
      body = ~s|<section><p>#{String.duplicate("Recoverable prose, with commas. ", 20)}</p></section>|
      {tree, root} = parse(body)
      options = Options.new()

      {tree, cleaned} = HtmlProcessing.tree_cleaning(tree, root, options)
      {tree, empty} = Tree.create(tree, "body")

      {_tree, result, text, length} =
        External.compare_extraction(tree, cleaned, root, empty, "", 0, options)

      assert length > 0
      assert text =~ "Recoverable prose"
      assert result != empty
    end

    test "keeps the rule-based result when it is already much longer" do
      {tree, root} = parse(~s|<p>short</p>|)
      options = Options.new()
      {tree, cleaned} = HtmlProcessing.tree_cleaning(tree, root, options)

      {tree, body} = Tree.create(tree, "body")
      {tree, paragraph} = Tree.create_child(tree, body, "p")
      own = String.duplicate("The extraction we already have, long and complete. ", 40)
      tree = Tree.put_text(tree, paragraph, own)

      {_tree, result, _text, _length} =
        External.compare_extraction(tree, cleaned, root, body, own, Text.len(own), options)

      assert result == body
    end
  end
end
