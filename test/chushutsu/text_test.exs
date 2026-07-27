defmodule Chushutsu.TextTest do
  use ExUnit.Case, async: true

  alias Chushutsu.Text

  describe "normalize_space/1" do
    test "collapses interior runs as well as the edges, unlike String.trim/1" do
      assert Text.normalize_space("  a   b\n\tc  ") == "a b c"
      assert Text.normalize_space("") == ""
      assert Text.normalize_space(nil) == ""
    end

    test "treats a non-breaking space as whitespace, like Python's str.split" do
      assert Text.normalize_space("a\u{00A0}b") == "a b"
      assert Text.normalize_space("\u{00A0}") == ""
    end

    test "keeps a zero-width space, which Python does not consider whitespace" do
      assert Text.normalize_space("a\u{200B}b") == "a\u{200B}b"
    end
  end

  describe "text_chars?/1" do
    test "detects strings with something other than whitespace" do
      assert Text.text_chars?("a")
      refute Text.text_chars?("   ")
      refute Text.text_chars?("")
      refute Text.text_chars?(nil)
    end
  end

  describe "remove_control_characters/1" do
    test "drops non-printable characters but keeps whitespace" do
      assert Text.remove_control_characters("a\0b") == "ab"
      assert Text.remove_control_characters("a\u{200B}b") == "ab"
      assert Text.remove_control_characters("a\tb\nc") == "a\tb\nc"
      assert Text.remove_control_characters("a\u{00A0}b") == "a\u{00A0}b"
    end
  end

  describe "line_processing/3" do
    test "converts spacing entities and collapses the line" do
      assert Text.line_processing("a&nbsp;b") == "a b"
      assert Text.line_processing("  x  ") == "x"
    end

    test "returns nil for a blank line" do
      assert Text.line_processing("   ") == nil
    end

    test "collapses newlines unless spacing is preserved" do
      # LINES_TRIMMING spares a newline after any of `p { P } >`, but the
      # trim() that follows collapses whatever survived, so the distinction
      # only shows up on the preserve_space path.
      assert Text.line_processing("a\nb", preserve_space: true) == "a\nb"
      assert Text.line_processing("a\nb") == "a b"
      assert Text.line_processing("p\nb") == "p b"
    end

    test "keeps flanking spaces when asked" do
      assert Text.line_processing(" x ", trailing_space: true) == " x "
      assert Text.line_processing("x", trailing_space: true) == "x"
    end
  end

  describe "sanitize/2" do
    test "processes line by line and drops blank lines" do
      assert Text.sanitize("a\n\n  \nb") == "a\nb"
    end

    test "treats the whole text as one line with trailing_space" do
      assert Text.sanitize("a b ", trailing_space: true) == "a b "
    end
  end

  describe "image_file?/1" do
    test "recognizes common image extensions" do
      assert Text.image_file?("/img/photo.jpg")
      assert Text.image_file?("https://x.test/a.webp?v=2")
      # trafilatura's IMAGE_EXTENSION is case-sensitive
      refute Text.image_file?("https://x.test/a.WEBP?v=2")
      refute Text.image_file?("/img/photo.svg")
      refute Text.image_file?("")
      refute Text.image_file?(nil)
    end

    test "rejects absurdly long sources" do
      refute Text.image_file?(String.duplicate("a", 9000) <> ".png")
    end
  end

  describe "filtered?/1" do
    test "matches social-media boilerplate lines" do
      assert Text.filtered?("Facebook")
      assert Text.filtered?("  Twitter")
      assert Text.filtered?("Mehr zum Thema:")
      refute Text.filtered?("Facebook is a company")
    end
  end

  describe "unescape/1" do
    test "resolves named and numeric HTML entities" do
      assert Text.unescape("a &amp; b &lt;c&gt; &#65; &#x42;") == "a & b <c> A B"
      assert Text.unescape("&nbsp;") == "\u{00A0}"
      assert Text.unescape("&unknownentity;") == "&unknownentity;"
    end
  end
end
