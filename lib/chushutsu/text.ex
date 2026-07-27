defmodule Chushutsu.Text do
  @moduledoc """
  String-level cleaning shared by every extraction stage.

  The rules here are deliberately faithful to trafilatura's, including a couple
  of quirks that the extraction heuristics were tuned around — see
  `line_processing/2` and the whitespace class below.
  """

  # Python's `str.split()` (and `str.isspace()`) treat these as whitespace.
  # Elixir's `String.split/1` disagrees at both ends: it leaves U+00A0 alone and
  # splits on U+200B. Collapsing must match Python's set, because `&nbsp;` is
  # deliberately turned into U+00A0 upstream and expected to collapse here.
  @whitespace ~S"\t\n\v\f\r \x{1c}-\x{1f}\x{85}\x{a0}\x{1680}\x{2000}-\x{200a}\x{2028}\x{2029}\x{202f}\x{205f}\x{3000}"
  @whitespace_re Regex.compile!("[#{@whitespace}]+", "u")
  @only_whitespace_re Regex.compile!("^[#{@whitespace}]*$", "u")

  # Characters in Unicode category "Other" that are not whitespace: unprintable,
  # and rejected outright by XML serializers.
  @unprintable_re ~r/[^\P{C}\t\n\v\f\r\x{1c}-\x{1f}\x{85}]/u

  # A newline is only collapsed when it does not follow one of `p { P } >`.
  # That character class reads like a Unicode property escape but is not one —
  # `re` treats `[p{P}>]` as five literal characters. The extraction thresholds
  # were calibrated against that behaviour, so it is reproduced verbatim.
  @lines_trimming ~r/(?<![p{P}>])\n/u

  @image_extension ~r/[^\s]+\.(avif|bmp|gif|hei[cf]|jpe?g|png|webp)(\b|$)/

  # Text-level counterpart to the social/share tokens in the discard xpaths.
  @filter_re ~r/^\W*(Drucken|E-?Mail|Facebook|Flipboard|Google|Instagram|Linkedin|Mail|PDF|Pinterest|Pocket|Print|QQ|Reddit|Twitter|WeChat|WeiBo|Whatsapp|Xing|Mehr zum Thema:?|More on this.{0,8}$)$/i

  @max_image_src_length 8192

  @doc "Collapses all whitespace runs to single spaces and strips the ends."
  @spec trim(String.t() | nil) :: String.t()
  def trim(nil), do: ""

  def trim(string) when is_binary(string) do
    string
    |> String.replace(@whitespace_re, " ")
    |> String.trim(" ")
  end

  def trim(_), do: ""

  @doc """
  Length in code points, matching Python's `len()`.

  Every threshold in the extractor was tuned against code-point counts, so
  `String.length/1` (which counts graphemes) would quietly shift them.
  """
  @spec len(String.t() | nil) :: non_neg_integer
  def len(nil), do: 0
  def len(string) when is_binary(string), do: count_code_points(string, 0)

  defp count_code_points(<<_::utf8, rest::binary>>, count), do: count_code_points(rest, count + 1)
  defp count_code_points(<<_, rest::binary>>, count), do: count_code_points(rest, count + 1)
  defp count_code_points(<<>>, count), do: count

  @doc "Whether the string holds anything other than whitespace."
  @spec text_chars?(String.t() | nil) :: boolean
  def text_chars?(nil), do: false
  def text_chars?(""), do: false
  def text_chars?(string) when is_binary(string), do: not blank?(string)
  def text_chars?(_), do: false

  @doc "Whether the string is empty or entirely whitespace."
  @spec blank?(String.t()) :: boolean
  def blank?(string), do: Regex.match?(@only_whitespace_re, string)

  @doc "Strips characters that are neither printable nor whitespace."
  @spec remove_control_characters(String.t() | nil) :: String.t() | nil
  def remove_control_characters(nil), do: nil
  def remove_control_characters(string), do: String.replace(string, @unprintable_re, "")

  @doc """
  Normalizes one line: spacing entities, control characters, collapsed whitespace.

  Returns `nil` when nothing but whitespace is left, so callers can drop the line.

  ## Options

    * `:preserve_space` — keep the line's internal spacing verbatim
    * `:trailing_space` — collapse the line but keep a single leading/trailing
      space if the original had one, so inline content does not get mashed
      together when segments are concatenated
  """
  @spec line_processing(String.t(), keyword) :: String.t() | nil
  def line_processing(line, opts \\ []) do
    new_line =
      line
      |> String.replace("&#13;", "\r")
      |> String.replace("&#10;", "\n")
      |> String.replace("&nbsp;", " ")
      |> remove_control_characters()

    if Keyword.get(opts, :preserve_space, false) do
      new_line
    else
      collapse_line(new_line, line, Keyword.get(opts, :trailing_space, false))
    end
  end

  defp collapse_line(new_line, original, trailing_space) do
    collapsed = new_line |> String.replace(@lines_trimming, " ") |> trim()

    cond do
      collapsed == "" -> nil
      trailing_space -> pad(collapsed, original)
      true -> collapsed
    end
  end

  defp pad(collapsed, original) do
    before = if starts_with_space?(original), do: " ", else: ""
    rest = if ends_with_space?(original), do: " ", else: ""
    before <> collapsed <> rest
  end

  defp starts_with_space?(<<>>), do: false
  defp starts_with_space?(string), do: string |> String.first() |> whitespace?()

  defp ends_with_space?(<<>>), do: false
  defp ends_with_space?(string), do: string |> String.last() |> whitespace?()

  defp whitespace?(char), do: Regex.match?(@only_whitespace_re, char) and char != ""

  @doc """
  Cleans a whole text, line by line, dropping blank lines.

  With `trailing_space: true` the text is treated as a single line instead, which
  is what the serializers want for inline runs.
  """
  @spec sanitize(String.t() | nil, keyword) :: String.t() | nil
  def sanitize(text, opts \\ [])
  def sanitize(nil, _opts), do: nil

  def sanitize(text, opts) do
    if Keyword.get(opts, :trailing_space, false) do
      line_processing(text, Keyword.put(opts, :trailing_space, true))
    else
      text
      |> String.split("\n")
      |> Enum.map(&line_processing(&1, opts))
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.join("\n")
      |> String.replace("␤", "")
    end
  end

  @doc "Whether a `src` value looks like an image file."
  @spec image_file?(String.t() | nil) :: boolean
  def image_file?(nil), do: false

  def image_file?(src) when is_binary(src) do
    byte_size(src) <= @max_image_src_length and Regex.match?(@image_extension, src)
  end

  def image_file?(_), do: false

  @doc "Whether a line is share/social boilerplate that should never be kept."
  @spec filtered?(String.t() | nil) :: boolean
  def filtered?(nil), do: false

  def filtered?(text) do
    text
    |> String.split("\n")
    |> Enum.any?(&Regex.match?(@filter_re, &1))
  end

  @doc "Resolves HTML entities (named, decimal and hexadecimal)."
  @spec unescape(String.t()) :: String.t()
  defdelegate unescape(text), to: Chushutsu.Text.Entities, as: :unescape

  @doc "Unicode NFC normalization, applied to every returned string."
  @spec normalize_unicode(String.t()) :: String.t()
  def normalize_unicode(string), do: :unicode.characters_to_nfc_binary(string)
end
