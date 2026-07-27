defmodule Chushutsu.Text.Entities do
  @moduledoc """
  HTML entity resolution matching Python's `html.unescape`.

  `HtmlEntities` covers the named references; numeric references are handled
  here so that malformed ones (out-of-range, surrogate) degrade to the
  replacement character rather than raising, which is what Python does.
  """

  @numeric ~r/&#(x[0-9a-fA-F]+|[0-9]+);?/

  @doc "Resolves named, decimal and hexadecimal character references."
  @spec unescape(String.t()) :: String.t()
  def unescape(text) when is_binary(text) do
    if String.contains?(text, "&") do
      text |> decode_numeric() |> HtmlEntities.decode()
    else
      text
    end
  end

  defp decode_numeric(text) do
    Regex.replace(@numeric, text, fn match, digits ->
      digits
      |> parse_code_point()
      |> to_character()
      |> Kernel.||(match)
    end)
  end

  defp parse_code_point("x" <> hex), do: hex |> Integer.parse(16) |> elem_or_nil()
  defp parse_code_point("X" <> hex), do: hex |> Integer.parse(16) |> elem_or_nil()
  defp parse_code_point(decimal), do: decimal |> Integer.parse(10) |> elem_or_nil()

  defp elem_or_nil({value, _rest}), do: value
  defp elem_or_nil(:error), do: nil

  defp to_character(nil), do: nil
  defp to_character(code) when code in 0xD800..0xDFFF, do: "�"
  defp to_character(code) when code < 0 or code > 0x10FFFF, do: "�"
  defp to_character(code), do: <<code::utf8>>
end
