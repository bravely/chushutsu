defmodule Chushutsu.Serialize.TextTest do
  use ExUnit.Case, async: true

  import Chushutsu.TreeHelpers

  alias Chushutsu.{Serialize, Tree}

  # Bodies are built directly rather than parsed: these shapes use the
  # extractor's internal vocabulary, which an HTML parser would rearrange.
  defp render(children, formatting \\ false) do
    {tree, body} = build({"body", [], List.wrap(children)})
    Serialize.Text.render(tree, body, formatting)
  end

  defp p(children), do: {"p", [], List.wrap(children)}

  # Markdown output ends with a trailing newline and plain text does not; both
  # match trafilatura, so the asymmetry is preserved rather than smoothed over.
  describe "block separation" do
    test "each paragraph lands on its own line" do
      assert render([p("one"), p("two")]) == "one\ntwo"
    end

    test "markdown separates blocks with a blank line" do
      assert render([p("one"), p("two")], true) == "one\n\ntwo\n"
    end
  end

  describe "headings" do
    test "renders the level from rend, defaulting to two" do
      assert render({"head", [{"rend", "h1"}], ["Title"]}, true) == "# Title\n"
      assert render({"head", [{"rend", "h4"}], ["Deep"]}, true) == "#### Deep\n"
      assert render({"head", [], ["Bare"]}, true) == "## Bare\n"
    end

    test "plain text drops the markers" do
      assert render({"head", [{"rend", "h1"}], ["Title"]}) == "Title"
    end
  end

  describe "inline formatting" do
    test "wraps emphasis, leaving flanking whitespace outside the markers" do
      assert render(p({"hi", [{"rend", "#b"}], ["bold"]}), true) == "**bold**\n"
      assert render(p({"hi", [{"rend", "#i"}], ["it"]}), true) == "*it*\n"
      assert render(p({"hi", [{"rend", "#u"}], ["u"]}), true) == "__u__\n"
    end

    test "renders monospace as an inline code span" do
      assert render(p({"hi", [{"rend", "#t"}], ["code"]}), true) == "`code`\n"
    end

    test "widens the fence when the text contains backticks" do
      assert render(p({"hi", [{"rend", "#t"}], ["a ` b"]}), true) == "``a ` b``\n"
    end

    test "strikethrough escapes an internal marker" do
      assert render(p({"del", [{"rend", "overstrike"}], ["gone"]}), true) == "~~gone~~\n"
    end
  end

  describe "links" do
    test "renders the target and escapes brackets in the label" do
      assert render(p({"ref", [{"target", "https://x.test"}], ["a [b] c"]}), true) ==
               "[a \\[b\\] c](https://x.test)\n"
    end

    test "a link without a target renders as a bare label" do
      assert render(p({"ref", [], ["label"]}), true) == "[label]\n"
    end

    test "a target containing spaces gets an angle-bracket destination" do
      assert render(p({"ref", [{"target", "https://x.test/a b"}], ["l"]}), true) ==
               "[l](<https://x.test/a b>)\n"
    end
  end

  describe "lists" do
    test "marks items" do
      list = {"list", [], [{"item", [], ["a"]}, {"item", [], ["b"]}]}
      assert render(list) == "- a\n- b"
    end

    test "numbers an ordered list only in markdown" do
      list = {"list", [{"rend", "ol"}], [{"item", [], ["a"]}, {"item", [], ["b"]}]}

      assert render(list, true) == "1. a\n2. b\n"
      # bare digits would read as content in plain text
      assert render(list) == "- a\n- b"
    end

    test "indents a nested list" do
      inner = {"list", [], [{"item", [], ["inner"]}]}
      list = {"list", [], [{"item", [], ["outer", inner]}]}

      assert render(list, true) =~ "  - inner"
    end
  end

  describe "tables" do
    test "renders pipes and a header separator" do
      table =
        {"table", [],
         [
           {"row", [], [{"cell", [{"role", "head"}], ["H"]}]},
           {"row", [], [{"cell", [], ["v"]}]}
         ]}

      output = render(table, true)

      assert output =~ "| H |"
      assert output =~ "|---|"
      assert output =~ "| v |"
    end

    test "a newline inside a cell becomes a space so the row survives" do
      table = {"table", [], [{"row", [], [{"cell", [], ["a\nb"]}]}]}
      assert render(table, true) =~ "| a b |"
    end

    test "a pipe inside a cell is escaped" do
      table = {"table", [], [{"row", [], [{"cell", [], ["a|b"]}]}]}
      assert render(table, true) =~ "a\\|b"
    end
  end

  describe "images" do
    test "combines title and alt into the label" do
      graphic = {"graphic", [{"src", "a.png"}, {"alt", "Alt"}, {"title", "Title"}], []}
      assert render(graphic, true) == "![Title Alt](a.png)\n"
    end
  end

  describe "math" do
    test "converts LaTeX delimiters to CommonMark dollars" do
      assert render(p("inline \\(x^2\\) here"), true) =~ "$x^2$"
      assert render(p("\\[a+b\\]"), true) =~ "$$\na+b\n$$"
    end

    test "leaves math delimiters alone inside code" do
      assert render({"code", [], ["\\(x\\)"]}, true) =~ "\\(x\\)"
    end
  end

  describe "emphasis collapsing" do
    test "splices out a redundant nested level" do
      nested = {"hi", [{"rend", "#b"}], [{"hi", [{"rend", "#b"}], ["x"]}]}
      assert render(p(nested), true) == "**x**\n"
    end

    test "keeps genuinely different levels" do
      nested = {"hi", [{"rend", "#b"}], [{"hi", [{"rend", "#i"}], ["x"]}]}
      assert render(p(nested), true) == "***x***\n"
    end
  end

  describe "edge cases" do
    test "an empty body renders as an empty string" do
      assert render([]) == ""
    end

    test "a nil body renders as an empty string" do
      assert Serialize.Text.render(Tree.new(), nil, false) == ""
    end

    test "an item with no enclosing list does not blow up on its indent" do
      assert render({"item", [], ["orphan"]}) =~ "orphan"
    end
  end
end
