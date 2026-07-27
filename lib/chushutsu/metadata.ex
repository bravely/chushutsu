defmodule Chushutsu.Metadata do
  @moduledoc """
  Scrapes title, author, date, site name and related fields from a page.

  Sources are consulted in order of trustworthiness: OpenGraph and standard
  `<meta>` tags first, then JSON-LD, then heuristics over the markup itself.
  Each field keeps the first non-empty value it gets, so a later, weaker source
  can fill a gap but never overwrite a stronger one.
  """

  require Logger

  alias Chushutsu.{Document, HtmlProcessing, Options, Selectors, Text, Tree, URL}

  @og_properties %{
    "og:title" => :title,
    "og:description" => :description,
    "og:site_name" => :sitename,
    "og:image" => :image,
    "og:image:url" => :image,
    "og:image:secure_url" => :image,
    "og:type" => :pagetype
  }

  @og_author ~w(og:author og:article:author)

  @metaname_author ~w(article:author atc-metaauthor author authors byl citation_author
                      creator dc.creator dc.creator.aut dc:creator dcterms.creator
                      dcterms.creator.aut dcsext.author parsely-author rbauthors
                      sailthru.author shareaholic:article_author_name)

  @metaname_description ~w(dc.description dc:description dcterms.abstract
                           dcterms.description description sailthru.description
                           twitter:description)

  @metaname_publisher ~w(article:publisher citation_journal_title copyright dc.publisher
                         dc:publisher dcterms.publisher publisher sailthru.publisher
                         rbpubname twitter:site)

  @metaname_tag ~w(citation_keywords dcterms.subject keywords parsely-tags
                   shareaholic:keywords tags)

  @metaname_title ~w(citation_title dc.title dcterms.title fb_title headline
                     parsely-title sailthru.title shareaholic:title rbtitle title
                     twitter:title)

  @metaname_url ~w(rbmainurl twitter:url)

  @metaname_image ~w(image og:image og:image:url og:image:secure_url twitter:image
                     twitter:image:src)

  @property_author ~w(author article:author)
  @twitter_attrs ~w(twitter:site application-name)

  # Titles are commonly "Headline — Site Name"; these separators split them.
  @html_title ~r/^(.+)?\s+[–•·—|⁄*⋆~‹«<›»>:-]\s+(.+)$/u
  @meta_url ~r"https?://(?:www\.|w[0-9]+\.)?([^/]+)"
  @license_url ~r"/(by-nc-nd|by-nc-sa|by-nc|by-nd|by-sa|by|zero)/([1-9]\.[0-9])"
  @license_text ~r/(cc|creative commons) (by-nc-nd|by-nc-sa|by-nc|by-nd|by-sa|by|zero) ?([1-9]\.[0-9])?/i
  @strip_tags ~r/(<!--.*?-->|<[^>]*>)/s
  @clean_meta_tags ~r/["']/

  @author_length_limit 120

  @doc "Extracts every metadata field it can find from a parsed tree."
  @spec extract(Tree.t(), Tree.id(), Options.t()) :: Document.t()
  def extract(tree, root, %Options{} = options) do
    %Document{}
    |> examine_meta(tree, root)
    |> drop_single_word_author()
    |> merge_json_ld(tree, root)
    |> fill_title(tree, root)
    |> apply_author_blacklist(options)
    |> fill_author(tree, root)
    |> apply_author_blacklist(options)
    |> fill_url(tree, root, options.url)
    |> fill_hostname()
    |> fill_date(tree, root)
    |> fill_sitename(tree, root)
    |> fill_categories(tree, root)
    |> fill_tags(tree, root)
    |> fill_license(tree, root)
    |> clean_and_trim()
  end

  # ## Meta tags -----------------------------------------------------------

  defp examine_meta(document, tree, root) do
    document = extract_opengraph(document, tree, root)

    if complete?(document) do
      document
    else
      tree
      |> head_meta_tags(root)
      |> Enum.reduce({document, []}, &absorb_meta_tag(tree, &1, &2))
      |> finish_meta()
    end
  end

  defp complete?(document) do
    Enum.all?(
      [document.title, document.author, document.url, document.description, document.sitename, document.image],
      &present?/1
    )
  end

  defp head_meta_tags(tree, root) do
    tree
    |> Tree.iterdescendants(root, ["meta"])
    |> Enum.filter(&(Tree.attr(tree, &1, "content") != nil))
  end

  defp extract_opengraph(document, tree, root) do
    tree
    |> head_meta_tags(root)
    |> Enum.filter(&String.starts_with?(Tree.attr(tree, &1, "property", ""), "og:"))
    |> Enum.reduce(document, fn id, document ->
      property = Tree.attr(tree, id, "property")
      content = Tree.attr(tree, id, "content")

      cond do
        not present?(content) -> document
        field = @og_properties[property] -> put_new(document, field, content)
        property == "og:url" -> put_new(document, :url, valid_url(content))
        property in @og_author -> put_new(document, :author, normalize_authors(nil, content))
        true -> document
      end
    end)
  end

  defp absorb_meta_tag(tree, id, {document, tags}) do
    content = tree |> Tree.attr(id, "content", "") |> strip_markup() |> String.trim()

    cond do
      content == "" ->
        {document, tags}

      property = Tree.attr(tree, id, "property") ->
        absorb_property(document, tags, String.downcase(property), content)

      name = Tree.attr(tree, id, "name") ->
        absorb_name(document, tags, String.downcase(name), content)

      true ->
        {document, tags}
    end
  end

  defp absorb_property(document, tags, property, content) do
    cond do
      # OpenGraph was already handled above
      String.starts_with?(property, "og:") -> {document, tags}
      property == "article:tag" -> {document, [normalize_tags(content) | tags]}
      property in @property_author -> {%{document | author: normalize_authors(document.author, content)}, tags}
      property == "article:publisher" -> {put_new(document, :sitename, content), tags}
      property in @metaname_image -> {put_new(document, :image, content), tags}
      true -> {document, tags}
    end
  end

  defp absorb_name(document, tags, name, content) do
    cond do
      name in @metaname_author ->
        {%{document | author: normalize_authors(document.author, content)}, tags}

      name in @metaname_title ->
        {put_new(document, :title, content), tags}

      name in @metaname_description ->
        {put_new(document, :description, content), tags}

      name in @metaname_publisher ->
        {put_new(document, :sitename, content), tags}

      name in @twitter_attrs or String.contains?(name, "twitter:app:name") ->
        {put_new(document, :sitename, content), tags}

      name in @metaname_url ->
        {put_new(document, :url, content), tags}

      name in @metaname_tag ->
        {document, [normalize_tags(content) | tags]}

      true ->
        {document, tags}
    end
  end

  defp finish_meta({document, tags}) do
    tags = tags |> Enum.reverse() |> Enum.reject(&(&1 in [nil, ""]))
    if document.tags == [] and tags != [], do: %{document | tags: tags}, else: document
  end

  # A bare single word is almost never a real byline; upstream drops it so the
  # markup heuristics get a chance instead.
  defp drop_single_word_author(document) do
    if present?(document.author) and not String.contains?(document.author, " "),
      do: %{document | author: nil},
      else: document
  end

  # ## JSON-LD -------------------------------------------------------------

  @json_types_person ~w(Person)
  @json_types_org ~w(Organization NewsMediaOrganization WebPage)

  defp merge_json_ld(document, tree, root) do
    tree
    |> Tree.iterdescendants(root, ["script"])
    |> Enum.filter(&(Tree.attr(tree, &1, "type") in ["application/ld+json", "application/settings+json"]))
    |> Enum.reduce(document, fn id, document ->
      case Jason.decode(Tree.text(tree, id) || "") do
        {:ok, decoded} -> absorb_json(document, decoded)
        {:error, _} -> document
      end
    end)
  rescue
    error ->
      Logger.warning("JSON-LD metadata extraction failed: #{Exception.message(error)}")
      document
  end

  defp absorb_json(document, value) when is_list(value),
    do: Enum.reduce(value, document, &absorb_json(&2, &1))

  defp absorb_json(document, %{} = node) do
    type = node |> Map.get("@type", "") |> to_string()

    document
    |> absorb_json_by_type(node, type)
    |> then(&Enum.reduce(["@graph", "mainEntity"], &1, fn key, doc -> absorb_json(doc, Map.get(node, key)) end))
  end

  defp absorb_json(document, _other), do: document

  defp absorb_json_by_type(document, node, type) do
    cond do
      type in @json_types_person ->
        put_new(document, :author, normalize_authors(document.author, Map.get(node, "name")))

      type in @json_types_org ->
        put_new(document, :sitename, string_or_name(Map.get(node, "name")))

      true ->
        absorb_json_article(document, node)
    end
  end

  defp absorb_json_article(document, node) do
    document
    |> put_new(:title, string_value(node["headline"] || node["name"]))
    |> put_new(:description, string_value(node["description"]))
    |> put_new(:date, first_date([node["datePublished"], node["dateCreated"]]))
    |> put_new(:author, json_author(node))
    |> put_new(:sitename, json_publisher(node))
    |> put_new(:license, string_value(node["license"]))
  end

  defp json_author(node) do
    node
    |> Map.get("author")
    |> List.wrap()
    |> Enum.map(&string_or_name/1)
    |> Enum.reject(&(&1 in [nil, ""]))
    |> case do
      [] -> nil
      names -> names |> Enum.join("; ") |> then(&normalize_authors(nil, &1))
    end
  end

  defp json_publisher(node) do
    case Map.get(node, "publisher") do
      %{"name" => name} when is_binary(name) -> name
      name when is_binary(name) -> name
      _other -> nil
    end
  end

  defp string_or_name(%{"name" => name}) when is_binary(name), do: name
  defp string_or_name(value) when is_binary(value), do: value
  defp string_or_name(_other), do: nil

  defp string_value(value) when is_binary(value), do: value
  defp string_value(_other), do: nil

  # ## Title ---------------------------------------------------------------

  defp fill_title(%Document{title: title} = document, _tree, _root) when is_binary(title) and title != "",
    do: document

  defp fill_title(document, tree, root) do
    %{document | title: extract_title(tree, root)}
  end

  defp extract_title(tree, root) do
    h1s = Tree.find_all(tree, root, "h1")

    with nil <- lone_h1(tree, h1s),
         nil <- metainfo(tree, root, Selectors.title()),
         nil <- title_from_head(tree, root),
         nil <- first_nonempty(tree, h1s) do
      first_nonempty(tree, Tree.find_all(tree, root, "h2"))
    end
  end

  defp lone_h1(tree, [only]), do: presence(Text.trim(Tree.text_content(tree, only)))
  defp lone_h1(_tree, _h1s), do: nil

  defp first_nonempty(tree, ids) do
    Enum.find_value(ids, fn id -> presence(Text.trim(Tree.text_content(tree, id))) end)
  end

  # A <title> is usually "Headline — Site"; the part without a dot in it is the
  # headline, the part with one is the domain.
  defp title_from_head(tree, root) do
    {full, first, second} = examine_title_element(tree, root)
    Enum.find([first, second, full], &(present?(&1) and not String.contains?(&1, ".")))
  end

  defp examine_title_element(tree, root) do
    case Tree.find(tree, root, "title") do
      nil ->
        {nil, nil, nil}

      id ->
        full = Text.trim(Tree.text_content(tree, id))

        case Regex.run(@html_title, full) do
          [_all, first, second] -> {full, Text.trim(first), Text.trim(second)}
          _ -> {full, nil, nil}
        end
    end
  end

  # ## Author --------------------------------------------------------------

  defp fill_author(%Document{author: author} = document, _tree, _root) when is_binary(author) and author != "",
    do: document

  defp fill_author(document, tree, root) do
    {tree, subtree} = Tree.deep_copy(tree, root)
    {tree, subtree} = HtmlProcessing.prune_unwanted_nodes(tree, subtree, Selectors.author_discard())

    author = metainfo(tree, subtree, Selectors.author(), @author_length_limit)
    %{document | author: normalize_authors(nil, author)}
  end

  defp apply_author_blacklist(document, %Options{author_blacklist: blacklist}) do
    cond do
      not present?(document.author) -> document
      MapSet.size(blacklist) == 0 -> document
      true -> %{document | author: check_authors(document.author, blacklist)}
    end
  end

  defp check_authors(authors, blacklist) do
    lowered = MapSet.new(blacklist, &String.downcase/1)

    authors
    |> String.split(";")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&MapSet.member?(lowered, String.downcase(&1)))
    |> case do
      [] -> nil
      kept -> kept |> Enum.join("; ") |> String.trim(";") |> String.trim()
    end
  end

  @author_noise ~r/^\s*(?:by|von|par|de|di|autor[ae]?|written by|posted by)\b[\s:]*/i

  @doc "Cleans a byline and appends it to any authors already found."
  @spec normalize_authors(String.t() | nil, String.t() | nil) :: String.t() | nil
  def normalize_authors(existing, nil), do: existing
  def normalize_authors(existing, ""), do: existing

  def normalize_authors(existing, new) do
    cleaned =
      new
      |> Text.unescape()
      |> String.replace(@author_noise, "")
      |> String.split(~r/\s*(?:,|;|\band\b|\bund\b|\bet\b)\s*/iu)
      |> Enum.map(&Text.trim/1)
      |> Enum.reject(&(&1 == "" or Text.len(&1) > @author_length_limit))
      |> Enum.uniq()

    case {existing, cleaned} do
      {_existing, []} -> existing
      {nil, names} -> Enum.join(names, "; ")
      {existing, names} -> ([existing] ++ names) |> Enum.uniq() |> Enum.join("; ")
    end
  end

  # First rule whose match yields usable text.
  defp metainfo(tree, root, rules, len_limit \\ 200) do
    Enum.find_value(rules, fn rule ->
      tree
      |> Selectors.select(root, rule)
      |> Enum.find_value(fn id ->
        text = Text.trim(Tree.text_content(tree, id))
        if text != "" and Text.len(text) < len_limit, do: text
      end)
    end)
  end

  # ## URL, hostname, site name --------------------------------------------

  defp fill_url(%Document{url: url} = document, _tree, _root, _default) when is_binary(url) and url != "",
    do: document

  defp fill_url(document, tree, root, default) do
    url =
      tree
      |> canonical_url(root)
      |> resolve_relative(tree, root)
      |> valid_url()

    %{document | url: url || default}
  end

  defp canonical_url(tree, root) do
    tree
    |> Tree.iterdescendants(root, ~w(link base))
    |> Enum.find_value(fn id ->
      rel = Tree.attr(tree, id, "rel")
      href = Tree.attr(tree, id, "href")

      cond do
        href in [nil, ""] -> nil
        Tree.tag(tree, id) == "base" -> href
        rel == "canonical" -> href
        rel == "alternate" and Tree.attr(tree, id, "hreflang") == "x-default" -> href
        true -> nil
      end
    end)
  end

  defp resolve_relative(nil, _tree, _root), do: nil

  defp resolve_relative("/" <> _ = path, tree, root) do
    base =
      tree
      |> head_meta_tags(root)
      |> Enum.find_value(fn id ->
        type = Tree.attr(tree, id, "name") || Tree.attr(tree, id, "property") || ""

        if String.starts_with?(type, "og:") or String.starts_with?(type, "twitter:"),
          do: URL.base_url(Tree.attr(tree, id, "content"))
      end)

    if base, do: base <> path, else: path
  end

  defp resolve_relative(url, _tree, _root), do: url

  defp valid_url(nil), do: nil

  defp valid_url(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) and host != "" -> url
      _ -> nil
    end
  end

  defp fill_hostname(%Document{url: nil} = document), do: document
  defp fill_hostname(document), do: %{document | hostname: URL.host(document.url)}

  defp fill_sitename(document, tree, root) do
    document
    |> put_new(:sitename, sitename_from_title(tree, root))
    |> normalize_sitename()
    |> sitename_from_url()
  end

  defp sitename_from_title(tree, root) do
    {_full, first, second} = examine_title_element(tree, root)
    Enum.find([first, second], &(present?(&1) and String.contains?(&1, ".")))
  end

  defp normalize_sitename(%Document{sitename: name} = document) when is_binary(name) do
    name = String.trim_leading(name, "@")

    name =
      if name != "" and not String.contains?(name, ".") and not upper_first?(name),
        do: titlecase(name),
        else: name

    %{document | sitename: name}
  end

  defp normalize_sitename(document), do: document

  defp sitename_from_url(%Document{sitename: name} = document) when is_binary(name) and name != "",
    do: document

  defp sitename_from_url(%Document{url: url} = document) when is_binary(url) do
    case Regex.run(@meta_url, url) do
      [_all, host] -> %{document | sitename: host}
      _ -> document
    end
  end

  defp sitename_from_url(document), do: document

  defp upper_first?(<<first::utf8, _rest::binary>>), do: <<first::utf8>> == String.upcase(<<first::utf8>>)
  defp upper_first?(_other), do: false

  defp titlecase(name) do
    name |> String.split(" ") |> Enum.map_join(" ", &capitalize_word/1)
  end

  defp capitalize_word(""), do: ""
  defp capitalize_word(word), do: String.capitalize(word)

  # ## Categories and tags -------------------------------------------------

  defp fill_categories(%Document{categories: [_ | _]} = document, _tree, _root), do: document

  defp fill_categories(document, tree, root) do
    case link_texts(tree, root, Selectors.categories(), ~r"/categor(?:y|ies|s)?/") do
      [] -> %{document | categories: section_meta(tree, root)}
      results -> %{document | categories: results}
    end
  end

  defp fill_tags(%Document{tags: [_ | _]} = document, _tree, _root), do: document

  defp fill_tags(document, tree, root) do
    %{document | tags: link_texts(tree, root, Selectors.tags(), ~r"/tag(?:y|ies|s)?/")}
  end

  defp link_texts(tree, root, rules, href_pattern) do
    Enum.find_value(rules, [], fn rule ->
      texts =
        tree
        |> Selectors.select(root, rule)
        |> Enum.flat_map(&Tree.find_all(tree, &1, "a"))
        |> Enum.filter(fn id ->
          href = Tree.attr(tree, id, "href")
          href != nil and Regex.match?(href_pattern, href)
        end)
        |> Enum.map(&Tree.text_content(tree, &1))
        |> clean_list()

      if texts != [], do: texts
    end)
  end

  defp section_meta(tree, root) do
    tree
    |> head_meta_tags(root)
    |> Enum.filter(fn id ->
      Tree.attr(tree, id, "property") == "article:section" or
        String.contains?(Tree.attr(tree, id, "name", ""), "subject")
    end)
    |> Enum.map(&Tree.attr(tree, &1, "content"))
    |> clean_list()
  end

  defp clean_list(values) do
    values
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.map(&Text.line_processing/1)
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.uniq()
  end

  # ## License -------------------------------------------------------------

  defp fill_license(document, tree, root) do
    %{document | license: extract_license(tree, root) || document.license}
  end

  defp extract_license(tree, root) do
    explicit =
      tree
      |> Tree.iterdescendants(root, ["a"])
      |> Enum.filter(&(Tree.attr(&1 |> then(fn _ -> tree end), &1, "rel") == "license"))
      |> Enum.find_value(&parse_license(tree, &1, false))

    explicit || footer_license(tree, root)
  end

  defp footer_license(tree, root) do
    tree
    |> Tree.iterdescendants(root)
    |> Enum.filter(&footer_container?(tree, &1))
    |> Enum.flat_map(&Tree.find_all(tree, &1, "a"))
    |> Enum.find_value(&parse_license(tree, &1, true))
  end

  defp footer_container?(tree, id) do
    Tree.tag(tree, id) == "footer" or
      (Tree.tag(tree, id) == "div" and
         Enum.any?(["class", "id"], &String.contains?(Tree.attr(tree, id, &1, ""), "footer")))
  end

  # The href carries the canonical Creative Commons identifier; the link text is
  # a weaker signal, so in strict mode only a fully-specified name counts.
  defp parse_license(tree, id, strict) do
    href = Tree.attr(tree, id, "href", "")

    case Regex.run(@license_url, href) do
      [_all, kind, version] ->
        "CC #{String.upcase(kind)} #{version}"

      _ ->
        text = Text.trim(Tree.text_content(tree, id))
        license_from_text(text, strict)
    end
  end

  defp license_from_text("", _strict), do: nil

  defp license_from_text(text, strict) do
    case Regex.run(@license_text, text) do
      [_all, _cc, kind, version] -> "CC #{String.upcase(kind)} #{version}" |> String.trim()
      [_all, _cc, kind] -> "CC #{String.upcase(kind)}"
      _ -> if strict, do: nil, else: presence(text)
    end
  end

  # ## Dates ---------------------------------------------------------------

  @date_meta_names ~w(article:published_time article:modified_time og:article:published_time
                      date dc.date dc.date.created dc.date.issued dcterms.date
                      dcterms.created citation_publication_date citation_date
                      sailthru.date parsely-pub-date pubdate publishdate
                      publish_date published-date article.published
                      article_date_original datepublished datecreated)

  @iso_date ~r/(\d{4})-(\d{2})-(\d{2})/
  @url_date ~r"/(\d{4})/(\d{2})/(\d{2})/"
  @url_date_short ~r"/(\d{4})/(\d{2})/"

  defp fill_date(%Document{date: date} = document, _tree, _root) when is_binary(date) and date != "" do
    %{document | date: normalize_date(date) || date}
  end

  defp fill_date(document, tree, root) do
    date =
      date_from_meta(tree, root) ||
        date_from_time_element(tree, root) ||
        date_from_url(document.url)

    %{document | date: date}
  end

  defp date_from_meta(tree, root) do
    tree
    |> head_meta_tags(root)
    |> Enum.filter(fn id ->
      name = (Tree.attr(tree, id, "name") || Tree.attr(tree, id, "property") || "") |> String.downcase()
      name in @date_meta_names
    end)
    |> Enum.map(&Tree.attr(tree, &1, "content"))
    |> first_date()
  end

  defp date_from_time_element(tree, root) do
    tree
    |> Tree.iterdescendants(root, ["time"])
    |> Enum.map(fn id -> Tree.attr(tree, id, "datetime") || Tree.text_content(tree, id) end)
    |> first_date()
  end

  defp date_from_url(nil), do: nil

  defp date_from_url(url) do
    case Regex.run(@url_date, url) do
      [_all, year, month, day] ->
        valid_date(year, month, day)

      _ ->
        case Regex.run(@url_date_short, url) do
          [_all, year, month] -> valid_date(year, month, "01")
          _ -> nil
        end
    end
  end

  defp first_date(values) do
    values
    |> List.wrap()
    |> Enum.filter(&is_binary/1)
    |> Enum.find_value(&normalize_date/1)
  end

  defp normalize_date(value) do
    case Regex.run(@iso_date, value) do
      [_all, year, month, day] -> valid_date(year, month, day)
      _ -> nil
    end
  end

  defp valid_date(year, month, day) do
    with {y, _} <- Integer.parse(year),
         {m, _} <- Integer.parse(month),
         {d, _} <- Integer.parse(day),
         {:ok, date} <- Date.new(y, m, d),
         # a date far in the future is a template placeholder, not a publication date
         :lt <- Date.compare(date, Date.add(Date.utc_today(), 1)) do
      Date.to_iso8601(date)
    else
      _ -> nil
    end
  end

  # ## Shared --------------------------------------------------------------

  defp clean_and_trim(document) do
    document
    |> Map.from_struct()
    |> Enum.map(fn
      {key, value} when is_binary(value) -> {key, clean_string(value)}
      pair -> pair
    end)
    |> then(&struct(Document, &1))
  end

  defp clean_string(value) do
    value = if Text.len(value) > 10_000, do: String.slice(value, 0, 9999) <> "…", else: value
    value |> Text.unescape() |> Text.line_processing() |> Kernel.||("")
  end

  defp put_new(document, _field, value) when value in [nil, ""], do: document

  defp put_new(document, field, value) do
    if present?(Map.get(document, field)), do: document, else: Map.put(document, field, value)
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  defp presence(""), do: nil
  defp presence(value), do: value

  defp strip_markup(text), do: String.replace(text, @strip_tags, "")

  defp normalize_tags(tags) do
    case tags |> Text.unescape() |> Text.trim() do
      "" ->
        ""

      trimmed ->
        trimmed
        |> String.replace(@clean_meta_tags, "")
        |> String.split(", ")
        |> Enum.reject(&(&1 == ""))
        |> Enum.join(", ")
    end
  end
end
