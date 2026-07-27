defmodule Chushutsu.External.JusText.Stoplists do
  @moduledoc """
  Stopword lists backing the jusText classifier.

  The lists ship gzipped in `priv/` and are decoded on first use, then cached in
  `:persistent_term` — they are large, immutable and read on every classified
  paragraph, which is exactly what that store is for.

  Data from the jusText project (BSD-2-Clause).
  """

  # ISO 639-1 codes to the language names jusText files its lists under.
  # Japanese and Chinese have no list, so they fall through to the union.
  @language_names %{
    "af" => "Afrikaans",
    "an" => "Aragonese",
    "ar" => "Arabic",
    "az" => "Azerbaijani",
    "be" => "Belarusian",
    "bg" => "Bulgarian",
    "bn" => "Bengali",
    "br" => "Breton",
    "bs" => "Bosnian",
    "ca" => "Catalan",
    "cs" => "Czech",
    "cy" => "Welsh",
    "da" => "Danish",
    "de" => "German",
    "el" => "Greek",
    "en" => "English",
    "eo" => "Esperanto",
    "es" => "Spanish",
    "et" => "Estonian",
    "eu" => "Basque",
    "fa" => "Persian",
    "fi" => "Finnish",
    "fr" => "French",
    "ga" => "Irish",
    "gl" => "Galician",
    "gu" => "Gujarati",
    "he" => "Hebrew",
    "hi" => "Hindi",
    "hr" => "Croatian",
    "ht" => "Haitian",
    "hu" => "Hungarian",
    "hy" => "Armenian",
    "id" => "Indonesian",
    "is" => "Icelandic",
    "it" => "Italian",
    "jv" => "Javanese",
    "ka" => "Georgian",
    "kk" => "Kazakh",
    "kn" => "Kannada",
    "ko" => "Korean",
    "ku" => "Kurdish",
    "ky" => "Kyrgyz",
    "la" => "Latin",
    "lb" => "Luxembourgish",
    "lt" => "Lithuanian",
    "lv" => "Latvian",
    "mk" => "Macedonian",
    "ml" => "Malayalam",
    "mr" => "Marathi",
    "ms" => "Malay",
    "mt" => "Maltese",
    "nb" => "Norwegian_Bokmal",
    "ne" => "Nepali",
    "nl" => "Dutch",
    "nn" => "Norwegian_Nynorsk",
    "no" => "Norwegian_Bokmal",
    "oc" => "Occitan",
    "pl" => "Polish",
    "pt" => "Portuguese",
    "qu" => "Quechua",
    "ro" => "Romanian",
    "ru" => "Russian",
    "sk" => "Slovak",
    "sl" => "Slovenian",
    "sq" => "Albanian",
    "sr" => "Serbian",
    "sv" => "Swedish",
    "sw" => "Swahili",
    "ta" => "Tamil",
    "te" => "Telugu",
    "tl" => "Tagalog",
    "tr" => "Turkish",
    "uk" => "Ukrainian",
    "ur" => "Urdu",
    "vi" => "Vietnamese",
    "vo" => "Volapuk",
    "wa" => "Walloon"
  }

  @doc """
  The stoplist for a language code, or the union of all of them.

  Trafilatura falls back to the union whenever no target language is set, which
  makes the density measure language-agnostic at the cost of some precision.
  """
  @spec for_language(String.t() | nil) :: MapSet.t(String.t())
  def for_language(nil), do: combined()

  def for_language(code) do
    case Map.fetch(@language_names, code) do
      {:ok, name} -> Map.get(by_language(), name, combined())
      :error -> combined()
    end
  end

  @doc "The union of every bundled stoplist."
  @spec combined() :: MapSet.t(String.t())
  def combined,
    do: cached(:combined, fn -> by_language() |> Map.values() |> Enum.reduce(MapSet.new(), &MapSet.union/2) end)

  @doc "Every stoplist, keyed by jusText's language name."
  @spec by_language() :: %{String.t() => MapSet.t(String.t())}
  def by_language, do: cached(:by_language, &load/0)

  defp load do
    :chushutsu
    |> :code.priv_dir()
    |> Path.join("justext_stoplists.json.gz")
    |> File.read!()
    |> :zlib.gunzip()
    |> Jason.decode!()
    |> Map.new(fn {language, words} ->
      {language, MapSet.new(words, &String.downcase/1)}
    end)
  end

  defp cached(key, builder) do
    term_key = {__MODULE__, key}

    case :persistent_term.get(term_key, :missing) do
      :missing ->
        value = builder.()
        :persistent_term.put(term_key, value)
        value

      value ->
        value
    end
  end
end
