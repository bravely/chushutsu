defmodule Chushutsu.Encoding do
  @moduledoc """
  Decodes page bytes to UTF-8.

  Most pages are UTF-8 and pass straight through. The rest declare a legacy
  codepage, and the declaration is trusted only as far as the HTML standard
  allows: a page labelled `ISO-8859-1` is decoded as windows-1252, because that
  is what the standard mandates and what browsers actually do.

  A page that declares UTF-8 but is not valid UTF-8 gets the same treatment as
  an undeclared one — decoded as windows-1252, which never fails and is right
  far more often than it is wrong for Western European content.
  """

  # Charset declarations live in the first few KB, inside <head>.
  @declaration_window 4096
  @charset ~r/charset\s*=\s*["']?\s*([A-Za-z0-9_\-]+)/i

  @doc """
  Decodes a page to a UTF-8 string.

  Binaries that are already valid UTF-8 are returned unchanged.
  """
  @spec decode(binary) :: String.t()
  def decode(bytes) when is_binary(bytes) do
    # :fast_ascii scans ASCII runs a word at a time and only falls back to the
    # per-code-point check on non-ASCII. Pages are overwhelmingly ASCII markup,
    # and this validates the whole document on every extraction.
    if String.valid?(bytes, :fast_ascii), do: bytes, else: transcode(bytes, detect(bytes))
  end

  @doc """
  The encoding a page declares, normalized to one this module can decode.

  Returns `:utf_8` when nothing is declared; callers only reach the legacy
  decoders once UTF-8 has already failed.
  """
  @spec detect(binary) :: atom
  def detect(bytes) do
    bytes
    |> binary_part(0, min(@declaration_window, byte_size(bytes)))
    |> then(&Regex.run(@charset, &1))
    |> case do
      [_match, label] -> normalize(label)
      _ -> :utf_8
    end
  end

  # Aliases follow the WHATWG encoding registry, which is what browsers use.
  defp normalize(label) do
    case label |> String.downcase() |> String.replace(~r/[^a-z0-9]/, "") do
      l when l in ~w(utf8 unicode11utf8) -> :utf_8
      # the standard maps every latin-1 label onto windows-1252
      l when l in ~w(iso88591 latin1 cp1252 windows1252 iso885915 latin9 ascii usascii) -> :windows_1252
      l when l in ~w(iso88592 latin2 cp1250 windows1250) -> :windows_1250
      _ -> :windows_1252
    end
  end

  # A declared UTF-8 that failed validation is broken, not UTF-8; fall back
  # rather than hand back bytes the parser will choke on.
  defp transcode(bytes, :utf_8), do: transcode(bytes, :windows_1252)

  defp transcode(bytes, codepage) do
    bytes
    |> :binary.bin_to_list()
    |> Enum.map(&<<map_byte(codepage, &1)::utf8>>)
    |> IO.iodata_to_binary()
  end

  # ASCII is shared by every supported codepage.
  defp map_byte(_codepage, byte) when byte < 0x80, do: byte

  # windows-1252
  defp map_byte(:windows_1252, 0x80), do: 0x20AC
  defp map_byte(:windows_1252, 0x82), do: 0x201A
  defp map_byte(:windows_1252, 0x83), do: 0x0192
  defp map_byte(:windows_1252, 0x84), do: 0x201E
  defp map_byte(:windows_1252, 0x85), do: 0x2026
  defp map_byte(:windows_1252, 0x86), do: 0x2020
  defp map_byte(:windows_1252, 0x87), do: 0x2021
  defp map_byte(:windows_1252, 0x88), do: 0x02C6
  defp map_byte(:windows_1252, 0x89), do: 0x2030
  defp map_byte(:windows_1252, 0x8A), do: 0x0160
  defp map_byte(:windows_1252, 0x8B), do: 0x2039
  defp map_byte(:windows_1252, 0x8C), do: 0x0152
  defp map_byte(:windows_1252, 0x8E), do: 0x017D
  defp map_byte(:windows_1252, 0x91), do: 0x2018
  defp map_byte(:windows_1252, 0x92), do: 0x2019
  defp map_byte(:windows_1252, 0x93), do: 0x201C
  defp map_byte(:windows_1252, 0x94), do: 0x201D
  defp map_byte(:windows_1252, 0x95), do: 0x2022
  defp map_byte(:windows_1252, 0x96), do: 0x2013
  defp map_byte(:windows_1252, 0x97), do: 0x2014
  defp map_byte(:windows_1252, 0x98), do: 0x02DC
  defp map_byte(:windows_1252, 0x99), do: 0x2122
  defp map_byte(:windows_1252, 0x9A), do: 0x0161
  defp map_byte(:windows_1252, 0x9B), do: 0x203A
  defp map_byte(:windows_1252, 0x9C), do: 0x0153
  defp map_byte(:windows_1252, 0x9E), do: 0x017E
  defp map_byte(:windows_1252, 0x9F), do: 0x0178

  # windows-1250
  defp map_byte(:windows_1250, 0x80), do: 0x20AC
  defp map_byte(:windows_1250, 0x82), do: 0x201A
  defp map_byte(:windows_1250, 0x84), do: 0x201E
  defp map_byte(:windows_1250, 0x85), do: 0x2026
  defp map_byte(:windows_1250, 0x86), do: 0x2020
  defp map_byte(:windows_1250, 0x87), do: 0x2021
  defp map_byte(:windows_1250, 0x89), do: 0x2030
  defp map_byte(:windows_1250, 0x8A), do: 0x0160
  defp map_byte(:windows_1250, 0x8B), do: 0x2039
  defp map_byte(:windows_1250, 0x8C), do: 0x015A
  defp map_byte(:windows_1250, 0x8D), do: 0x0164
  defp map_byte(:windows_1250, 0x8E), do: 0x017D
  defp map_byte(:windows_1250, 0x8F), do: 0x0179
  defp map_byte(:windows_1250, 0x91), do: 0x2018
  defp map_byte(:windows_1250, 0x92), do: 0x2019
  defp map_byte(:windows_1250, 0x93), do: 0x201C
  defp map_byte(:windows_1250, 0x94), do: 0x201D
  defp map_byte(:windows_1250, 0x95), do: 0x2022
  defp map_byte(:windows_1250, 0x96), do: 0x2013
  defp map_byte(:windows_1250, 0x97), do: 0x2014
  defp map_byte(:windows_1250, 0x99), do: 0x2122
  defp map_byte(:windows_1250, 0x9A), do: 0x0161
  defp map_byte(:windows_1250, 0x9B), do: 0x203A
  defp map_byte(:windows_1250, 0x9C), do: 0x015B
  defp map_byte(:windows_1250, 0x9D), do: 0x0165
  defp map_byte(:windows_1250, 0x9E), do: 0x017E
  defp map_byte(:windows_1250, 0x9F), do: 0x017A
  defp map_byte(:windows_1250, 0xA1), do: 0x02C7
  defp map_byte(:windows_1250, 0xA2), do: 0x02D8
  defp map_byte(:windows_1250, 0xA3), do: 0x0141
  defp map_byte(:windows_1250, 0xA5), do: 0x0104
  defp map_byte(:windows_1250, 0xAA), do: 0x015E
  defp map_byte(:windows_1250, 0xAF), do: 0x017B
  defp map_byte(:windows_1250, 0xB2), do: 0x02DB
  defp map_byte(:windows_1250, 0xB3), do: 0x0142
  defp map_byte(:windows_1250, 0xB9), do: 0x0105
  defp map_byte(:windows_1250, 0xBA), do: 0x015F
  defp map_byte(:windows_1250, 0xBC), do: 0x013D
  defp map_byte(:windows_1250, 0xBD), do: 0x02DD
  defp map_byte(:windows_1250, 0xBE), do: 0x013E
  defp map_byte(:windows_1250, 0xBF), do: 0x017C
  defp map_byte(:windows_1250, 0xC0), do: 0x0154
  defp map_byte(:windows_1250, 0xC3), do: 0x0102
  defp map_byte(:windows_1250, 0xC5), do: 0x0139
  defp map_byte(:windows_1250, 0xC6), do: 0x0106
  defp map_byte(:windows_1250, 0xC8), do: 0x010C
  defp map_byte(:windows_1250, 0xCA), do: 0x0118
  defp map_byte(:windows_1250, 0xCC), do: 0x011A
  defp map_byte(:windows_1250, 0xCF), do: 0x010E
  defp map_byte(:windows_1250, 0xD0), do: 0x0110
  defp map_byte(:windows_1250, 0xD1), do: 0x0143
  defp map_byte(:windows_1250, 0xD2), do: 0x0147
  defp map_byte(:windows_1250, 0xD5), do: 0x0150
  defp map_byte(:windows_1250, 0xD8), do: 0x0158
  defp map_byte(:windows_1250, 0xD9), do: 0x016E
  defp map_byte(:windows_1250, 0xDB), do: 0x0170
  defp map_byte(:windows_1250, 0xDE), do: 0x0162
  defp map_byte(:windows_1250, 0xE0), do: 0x0155
  defp map_byte(:windows_1250, 0xE3), do: 0x0103
  defp map_byte(:windows_1250, 0xE5), do: 0x013A
  defp map_byte(:windows_1250, 0xE6), do: 0x0107
  defp map_byte(:windows_1250, 0xE8), do: 0x010D
  defp map_byte(:windows_1250, 0xEA), do: 0x0119
  defp map_byte(:windows_1250, 0xEC), do: 0x011B
  defp map_byte(:windows_1250, 0xEF), do: 0x010F
  defp map_byte(:windows_1250, 0xF0), do: 0x0111
  defp map_byte(:windows_1250, 0xF1), do: 0x0144
  defp map_byte(:windows_1250, 0xF2), do: 0x0148
  defp map_byte(:windows_1250, 0xF5), do: 0x0151
  defp map_byte(:windows_1250, 0xF8), do: 0x0159
  defp map_byte(:windows_1250, 0xF9), do: 0x016F
  defp map_byte(:windows_1250, 0xFB), do: 0x0171
  defp map_byte(:windows_1250, 0xFE), do: 0x0163
  defp map_byte(:windows_1250, 0xFF), do: 0x02D9

  # Unmapped high bytes keep their latin-1 value, which is the identity mapping
  # for most of the range and harmless for the handful of undefined slots.
  defp map_byte(_codepage, byte), do: byte
end
