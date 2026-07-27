defmodule Chushutsu.Tree.Parser do
  @moduledoc """
  HTML parsing, with the same up-front repairs trafilatura performs.

  Real-world pages carry markup that trips parsers: XML control characters, a
  `<!DOCTYPE ... />` first line, a self-closing `<html/>`. These are patched
  before parsing rather than worked around afterwards.
  """

  # Control characters that are invalid in XML and that lxml refuses in text nodes.
  @invalid_chars ~r/[\x{0}-\x{8}\x{b}\x{c}\x{e}-\x{1f}\x{fffe}\x{ffff}]/u
  @doctype_tag ~r/^< ?! ?DOCTYPE[^>]*\/[^<>]*>/i
  @faulty_html ~r/(<html.*?)\s*\/>/i

  @doc """
  Parses an HTML document, returning Floki's node tree.

  Returns `:error` when the input does not parse into anything usable.
  """
  @spec document(binary) :: {:ok, term} | :error
  def document(html) when is_binary(html) do
    html
    |> Chushutsu.Encoding.decode()
    |> repair()
    |> Floki.parse_document()
    |> case do
      {:ok, parsed} -> {:ok, parsed}
      _ -> :error
    end
  end

  @doc """
  Parses a fragment of HTML that is not a whole document.

  Used for content embedded in JSON-LD, where markup arrives as a bare run of
  elements with no `<html>` wrapper.
  """
  @spec fragment(binary) :: {:ok, term} | :error
  def fragment(html) when is_binary(html) do
    case Floki.parse_fragment(html) do
      {:ok, parsed} -> {:ok, parsed}
      _ -> :error
    end
  end

  @doc "Applies trafilatura's `repair_faulty_html` fixes."
  @spec repair(binary) :: binary
  def repair(html) do
    beginning = html |> binary_part(0, min(50, byte_size(html))) |> String.downcase()

    html
    |> strip_invalid_chars()
    |> fix_doctype(beginning)
    |> fix_self_closing_html()
  end

  defp strip_invalid_chars(html) do
    if String.valid?(html), do: String.replace(html, @invalid_chars, ""), else: html
  end

  defp fix_doctype(html, beginning) do
    if String.contains?(beginning, "doctype") do
      case String.split(html, "\n", parts: 2) do
        [first, rest] -> String.replace(first, @doctype_tag, "", global: false) <> "\n" <> rest
        [only] -> String.replace(only, @doctype_tag, "", global: false)
      end
    else
      html
    end
  end

  # `<html ... />` makes libxml2 (and html5ever) treat the whole document as empty.
  defp fix_self_closing_html(html) do
    html
    |> String.split("\n")
    |> Enum.take(3)
    |> Enum.any?(&(String.contains?(&1, "<html") and String.ends_with?(&1, "/>")))
    |> case do
      true -> String.replace(html, @faulty_html, "\\1>", global: false)
      false -> html
    end
  end
end
