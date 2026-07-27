defmodule Chushutsu.EncodingTest do
  use ExUnit.Case, async: true

  alias Chushutsu.Encoding

  describe "decode/1" do
    test "passes valid UTF-8 through untouched" do
      utf8 = "Bayern fordert höhere Erlösobergrenzen — 日本語"
      assert Encoding.decode(utf8) == utf8
    end

    test "decodes a page declaring iso-8859-1" do
      bytes = <<"<meta charset=\"iso-8859-1\"><p>h", 0xF6, "here Erl", 0xF6, "s</p>">>

      assert Encoding.decode(bytes) =~ "höhere Erlös"
    end

    test "decodes windows-1252 punctuation that latin-1 leaves undefined" do
      # 0x93/0x94 are curly quotes in windows-1252 and control codes in latin-1
      bytes = <<"<meta charset=\"windows-1252\"><p>", 0x93, "quoted", 0x94, " 80", 0x80, "</p>">>
      decoded = Encoding.decode(bytes)

      assert decoded =~ "“quoted”"
      assert decoded =~ "€"
    end

    test "treats an iso-8859-1 label as windows-1252, per the HTML standard" do
      bytes = <<"<meta charset=\"iso-8859-1\"><p>", 0x93, "q", 0x94, "</p>">>
      assert Encoding.decode(bytes) =~ "“q”"
    end

    test "decodes windows-1250 for Central European pages" do
      # 0x9C is 'ś' in windows-1250 but 'œ' in windows-1252
      bytes = <<"<meta charset=\"windows-1250\"><p>", 0x9C, "</p>">>
      assert Encoding.decode(bytes) =~ "ś"
    end

    test "falls back to windows-1252 when a page lies about being UTF-8" do
      bytes = <<"<meta charset=\"utf-8\"><p>caf", 0xE9, "</p>">>

      decoded = Encoding.decode(bytes)
      assert String.valid?(decoded)
      assert decoded =~ "café"
    end

    test "falls back when nothing is declared" do
      bytes = <<"<p>caf", 0xE9, "</p>">>

      decoded = Encoding.decode(bytes)
      assert String.valid?(decoded)
      assert decoded =~ "café"
    end

    test "always produces a valid UTF-8 string" do
      bytes = for b <- 0..255, into: <<>>, do: <<b>>
      assert String.valid?(Encoding.decode(bytes))
    end
  end

  describe "detect/1" do
    test "recognizes declared charsets and their aliases" do
      assert Encoding.detect(~s|<meta charset="utf-8">|) == :utf_8
      assert Encoding.detect(~s|<meta charset="UTF8">|) == :utf_8

      assert Encoding.detect(~s|<meta http-equiv="Content-Type" content="text/html; charset=ISO-8859-1">|) ==
               :windows_1252

      assert Encoding.detect(~s|<meta charset='windows-1250'>|) == :windows_1250
    end

    test "assumes UTF-8 when nothing is declared" do
      assert Encoding.detect("<html><body>x</body></html>") == :utf_8
    end

    test "ignores a declaration that appears far past the head" do
      padded = String.duplicate(" ", 5000) <> ~s|<meta charset="windows-1250">|
      assert Encoding.detect(padded) == :utf_8
    end
  end

  describe "end-to-end" do
    test "a legacy-encoded page extracts readable text" do
      prose = "Die Erlösobergrenzen für Bioenergie sind höher als erwartet. "
      latin1 = :unicode.characters_to_binary(String.duplicate(prose, 8), :utf8, :latin1)

      html =
        <<"<html><head><meta charset=\"iso-8859-1\"><title>T</title></head>", "<body><div class=\"post-content\"><p>",
          latin1::binary, "</p></div></body></html>">>

      assert {:ok, text} = Chushutsu.extract(html)
      assert text =~ "Erlösobergrenzen"
      assert text =~ "höher"
    end
  end
end
