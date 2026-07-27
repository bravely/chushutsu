defmodule Chushutsu.Settings do
  @moduledoc """
  Tag catalogues and tuned constants shared across the extraction stages.

  The numeric thresholds were calibrated upstream as a *set* against a benchmark
  suite; changing one in isolation tends to move the others' behaviour, so they
  are kept together and documented rather than scattered through the code.
  """

  # ## Tag sets ------------------------------------------------------------

  @tag_catalog ~w(blockquote code del head hi lb list p pre quote)

  @doc "The internal (TEI-flavoured) tags the extractor is willing to emit."
  def tag_catalog, do: @tag_catalog

  @doc "Elements dropped entirely: chrome, media and interactive controls."
  def manually_cleaned do
    ~w(aside embed fencedframe footer form head iframe menu object script) ++
      ~w(applet audio canvas figure map picture svg video) ++
      ~w(area blink button datalist dialog frame frameset fieldset link input ins
         label legend marquee math menuitem nav noindex noscript optgroup option
         output param progress rp rt rtc select source style track textarea time use)
  end

  @doc "Elements unwrapped in place: their text is content, their tag is noise."
  def manually_stripped do
    ~w(abbr acronym address bdi bdo big cite data dfn font hgroup img ins mark meta
       nobr ruby small tbody template tfoot thead)
  end

  @doc "Empty elements worth deleting to save downstream work."
  def cut_empty_elems do
    ~w(article b blockquote dd div dt em h1 h2 h3 h4 h5 h6 i li main p pre q section span strong)
  end

  # ## The inline-tag ladder -----------------------------------------------
  #
  # A single source of truth shared by the extractor and the serializers.

  @inline_consuming ~w(hi ref del)
  @inline_formattable @inline_consuming ++ ["code"]
  @inline_carried @inline_formattable ++ ["graphic"]

  @doc "Elements that fold their children into their own text."
  def inline_consuming, do: @inline_consuming

  @doc "`inline_consuming/0` plus `code`, which has text rendered verbatim."
  def inline_formattable, do: @inline_formattable

  @doc "`inline_formattable/0` plus `graphic`, which renders as image markup."
  def inline_carried, do: @inline_carried

  @doc "Elements whose flanking spaces must survive text cleaning."
  def formatting_protected, do: ~w(cell head hi item p quote ref td)

  @doc "Elements whose internal spacing is significant."
  def spacing_protected, do: ~w(code pre)

  @doc "Tags valid in TEI output."
  def tei_valid_tags do
    ~w(ab body cell code del div graphic head hi item lb list p quote ref row table)
  end

  @doc "Attributes valid in TEI output."
  def tei_valid_attrs, do: ~w(rend rendition role target type)

  # ## Thresholds ----------------------------------------------------------

  @doc "Minimum characters for an extraction to be considered adequate."
  def min_extracted_size, do: 250

  @doc "Minimum characters before a document is discarded outright."
  def min_output_size, do: 1

  @doc "Minimum characters of comments before they are dropped."
  def min_extracted_comm_size, do: 1
  def min_output_comm_size, do: 1

  @doc "Minimum length before a segment participates in duplicate detection."
  def min_duplcheck_size, do: 100

  @doc "How many times a segment may repeat before it counts as a duplicate."
  def max_repetitions, do: 2

  @doc """
  Minimum length for a repeated span to count as an extraction artifact.

  Below this, a repeat is more likely to be genuine content (a recurring
  heading) than the same block picked up twice.
  """
  def min_duplicate_length, do: 50

  @doc """
  Cap on the accumulated text the substring-dedup scans will search.

  Those scans are quadratic in accumulated text; no corpus page comes close to
  this, it only guards a pathological input.
  """
  def dedupe_scan_cap, do: 200_000

  @doc "Capacity of the cross-document duplicate cache."
  def lru_size, do: 4096

  # ## Recall escalation ---------------------------------------------------

  @doc "Only extractions below this length are considered for escalation."
  def escalation_max_length, do: 3000

  @doc "...and only when they cover less than this share of the page's text."
  def escalation_page_share, do: 0.2

  @doc "A recall retry is adopted when it is at least this much longer."
  def escalation_accept_ratio, do: 1.5

  @doc """
  A justext candidate needs a stricter bar than the rule-based retry.

  justext tends to over-include — whole pricing tables, unrelated sections —
  rather than stop at page boundaries the way the rule retry does.
  """
  def escalation_justext_ratio, do: 2.0

  @doc "justext only displaces the main text when that text is not much longer."
  def justext_override_ratio, do: 3

  @doc "Link text above this share of an element's text marks it as a link farm."
  def link_farm_ratio, do: 0.9

  # ## Markdown rendering --------------------------------------------------

  @doc "Elements that start on a new line in text output."
  def newline_elems, do: ~w(graphic head lb list p quote row table)

  @doc "Elements that manage their own trailing separator."
  def special_formatting, do: ~w(code del head hi ref item cell)

  @doc "Elements permitted to keep attributes in XML output."
  def with_attributes, do: ~w(cell row del graphic head hi item list ref)

  @doc "Containers in which same-tag nesting is legitimate."
  def nesting_whitelist, do: ~w(cell figure item note quote)

  @doc "Mapping from `hi/@rend` to its markdown marker."
  def hi_formatting, do: %{"#b" => "**", "#i" => "*", "#u" => "__", "#t" => "`"}

  @doc "Mapping from HTML formatting tags to the `rend` value they become."
  def rend_tag_mapping do
    %{
      "em" => "#i",
      "i" => "#i",
      "b" => "#b",
      "strong" => "#b",
      "u" => "#u",
      "kbd" => "#t",
      "samp" => "#t",
      "tt" => "#t",
      "var" => "#t",
      "sub" => "#sub",
      "sup" => "#sup"
    }
  end

  @doc "Metadata fields carried into serialized output, in order."
  def meta_attributes do
    ~w(sitename title author date url hostname description categories tags license id fingerprint language)a
  end
end
