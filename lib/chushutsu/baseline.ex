defmodule Chushutsu.Baseline do
  @moduledoc """
  Fallback extraction that does not depend on finding a content area.

  Tries a series of increasingly desperate sources and takes the first that
  yields enough text: content embedded as JSON (schema.org properties, Discourse
  forum posts), `<article>` elements, text paragraphs, schema.org teaser
  descriptions, and finally a dump of the whole body.
  """

  alias Chushutsu.{Text, Tree}

  # schema.org properties that carry page content outright.
  @json_text_keys ~w(articleBody reviewBody)

  # Types whose *description* is the closest thing to content: short summaries,
  # only usable once every full-text source has come up empty.
  @description_types ~w(Product VideoObject)

  # Cheap pre-filter so pages without any of this are not JSON-parsed at all.
  @json_hooks @json_text_keys ++
                ["recipeInstructions", "acceptedAnswer"] ++
                Enum.map(@description_types ++ ["HowTo"], &~s|"#{&1}"|)

  # A strategy must accumulate more than this to be accepted, and a single
  # <article> must carry more than this to count as content at all.
  @min_content_length 100

  @cookie_consent ~r/cookie[-_]?(?:banner|bar|consent|law|notice|policy|description)|notice[-_]{0,2}cookie|consent[-_]?(?:banner|manager|sdk)|borlabs|cookiebot|cmplz|onetrust|moove[-_]?gdpr/i

  # Block-level elements, whose boundaries separate text runs. Minified pages
  # carry no whitespace there, so it has to be reinserted.
  @block_elems ~w(address article aside blockquote br dd div dl dt figcaption figure
                  footer form h1 h2 h3 h4 h5 h6 header hr li main nav ol p pre section
                  summary table td th tr ul)

  @doc """
  Runs baseline extraction over a parsed tree.

  Returns `{tree, body_id, text, length}`; the input tree is left untouched.
  """
  @spec extract(Tree.t(), Tree.id()) :: {Tree.t(), Tree.id(), String.t(), non_neg_integer}
  def extract(tree, root) do
    {tree, working} = Tree.deep_copy(tree, root)
    {bodies, teasers} = collect_json_content(tree, working)

    # Pages routinely embed the same JSON-LD block twice (theme plus SEO plugin).
    with nil <- attempt(tree, Enum.map(bodies, &render_embedded/1), dedupe: true),
         tree <- basic_cleaning(tree, working),
         nil <- article_strategy(tree, working),
         nil <- paragraph_strategy(tree, working) do
      last_resort(tree, working, teasers)
    else
      {:ok, result} -> result
    end
  end

  @doc """
  Strips the sections that are never content: chrome, scripts and cookie banners.

  Consent banners are matched on anchored compounds and known CMP vendors rather
  than a bare `cookie` substring — the loose version matched WordPress body
  classes and topical content, deleting most of some pages.
  """
  @spec basic_cleaning(Tree.t(), Tree.id()) :: Tree.t()
  def basic_cleaning(tree, root) do
    tree
    |> Tree.iterdescendants(root)
    |> Enum.filter(&unwanted_section?(tree, &1))
    |> Enum.reduce(tree, fn id, tree ->
      if Tree.exists?(tree, id), do: Tree.delete_element(tree, id), else: tree
    end)
  end

  defp unwanted_section?(tree, id) do
    tag = Tree.tag(tree, id)

    tag in ~w(aside fencedframe footer script style svg template) or
      (tag == "div" and first_contains?(tree, id, ["class", "id"], "footer")) or
      consent_banner?(tree, id)
  end

  defp consent_banner?(tree, id) do
    Enum.any?(["class", "id"], fn name ->
      case Tree.attr(tree, id, name) do
        nil -> false
        value -> Regex.match?(@cookie_consent, value)
      end
    end)
  end

  defp first_contains?(tree, id, names, needle) do
    case Tree.first_attr(tree, id, names) do
      nil -> false
      value -> String.contains?(value, needle)
    end
  end

  # ## Strategies ----------------------------------------------------------

  # A dominant <article> relegates much smaller siblings to noise (related
  # teasers); similarly-sized ones are all content (forum posts). Nested
  # articles are excluded, having been counted inside their ancestor.
  defp article_strategy(tree, root) do
    texts =
      tree
      |> Tree.iterdescendants(root, ["article"])
      |> Enum.reject(&Tree.has_ancestor?(tree, &1, ["article"]))
      |> Enum.map(&Text.normalize_space(Tree.text_content(tree, &1)))
      |> Enum.filter(&(Text.len(&1) > @min_content_length))

    case texts do
      [] ->
        nil

      texts ->
        cutoff = texts |> Enum.map(&Text.len/1) |> Enum.max() |> div(5)
        attempt(tree, Enum.filter(texts, &(Text.len(&1) >= cutoff)))
    end
  end

  # Nested elements duplicate part of their container's text, and containers are
  # collected first in document order, so repeats are dropped.
  defp paragraph_strategy(tree, root) do
    tree
    |> Tree.iterdescendants(root, ~w(blockquote code p pre q quote))
    |> Enum.map(&Text.normalize_space(Tree.text_content(tree, &1)))
    |> then(&attempt(tree, &1, dedupe: true))
  end

  defp last_resort(tree, root, teasers) do
    teaser = attempt(tree, Enum.map(teasers, &render_embedded/1), dedupe: true)

    case Tree.find(tree, root, "body") || root do
      nil ->
        teaser_or_empty(tree, teaser)

      body_elem ->
        text =
          tree
          |> Tree.itertext(body_elem)
          |> Enum.map(&Text.normalize_space/1)
          |> Enum.reject(&(&1 == ""))
          |> Enum.join("\n")
          |> Text.remove_control_characters()

        # a short summary must not shadow a longer dump
        if teaser && Text.len(text) < teaser_length(teaser),
          do: unwrap(teaser),
          else: build_result(tree, [text], dedupe: false, force: true)
    end
  end

  defp teaser_or_empty(tree, nil) do
    {tree, body} = Tree.create(tree, "body")
    {tree, body, "", 0}
  end

  defp teaser_or_empty(_tree, teaser), do: unwrap(teaser)

  defp teaser_length({:ok, {_tree, _body, _text, length}}), do: length
  defp unwrap({:ok, result}), do: result

  # ## Body building -------------------------------------------------------

  defp attempt(tree, texts, opts \\ []) do
    case build_result(tree, texts, opts) do
      {_tree, _body, text, _length} = result ->
        if Text.len(text) > @min_content_length, do: {:ok, result}, else: nil
    end
  end

  defp build_result(tree, texts, opts) do
    dedupe = Keyword.get(opts, :dedupe, false)
    {tree, body} = Tree.create(tree, "body")

    {tree, collected} =
      Enum.reduce(texts, {tree, []}, fn text, {tree, collected} ->
        text = Text.remove_control_characters(text)

        if keep_paragraph?(text, collected, dedupe) do
          {tree, paragraph} = Tree.create_child(tree, body, "p")
          {Tree.put_text(tree, paragraph, text), [text | collected]}
        else
          {tree, collected}
        end
      end)

    text = collected |> Enum.reverse() |> Enum.join("\n")
    {tree, body, text, Text.len(text)}
  end

  # Short paragraphs are kept even when they recur — only long substring repeats
  # (a <p> nested inside its <blockquote>) are extraction artifacts.
  defp keep_paragraph?(text, _collected, _dedupe) when text in [nil, ""], do: false
  defp keep_paragraph?(_text, _collected, false), do: true

  defp keep_paragraph?(text, collected, true) do
    joined = collected |> Enum.reverse() |> Enum.join("\n")

    Text.len(text) <= Chushutsu.Settings.min_duplicate_length() or
      Text.len(joined) > Chushutsu.Settings.dedupe_scan_cap() or
      not String.contains?(joined, text)
  end

  # ## Embedded JSON -------------------------------------------------------

  defp collect_json_content(tree, root) do
    {bodies, teasers} =
      tree
      |> Tree.iterdescendants(root, ["script"])
      |> Enum.filter(&(Tree.attr(tree, &1, "type") == "application/ld+json"))
      |> Enum.reduce({[], []}, fn script, acc ->
        text = Tree.text(tree, script)

        if text && String.contains?(text, @json_hooks) do
          case Jason.decode(text) do
            {:ok, decoded} -> walk_json(decoded, acc)
            {:error, _} -> acc
          end
        else
          acc
        end
      end)

    {Enum.reverse(bodies) ++ discourse_texts(tree, root), Enum.reverse(teasers)}
  end

  # Collects schema.org text from parsed JSON-LD, including list-wrapped and
  # @graph-nested nodes.
  defp walk_json(node, acc) do
    node
    |> as_list()
    |> Enum.reduce(acc, fn
      item, acc when is_map(item) -> collect_json_item(item, acc)
      _item, acc -> acc
    end)
  end

  defp collect_json_item(item, {bodies, teasers}) do
    bodies = Enum.reduce(@json_text_keys, bodies, &prepend_string(Map.get(item, &1), &2))
    bodies = Enum.reduce(["recipeInstructions", "step"], bodies, &collect_steps(Map.get(item, &1), &2))
    bodies = collect_answer(Map.get(item, "acceptedAnswer"), bodies)
    teasers = collect_teaser(item, teasers)

    {bodies, teasers} =
      Enum.reduce(["@graph", "mainEntity"], {bodies, teasers}, fn key, acc ->
        walk_json(Map.get(item, key), acc)
      end)

    {bodies, teasers}
  end

  # Recipe and how-to instructions arrive as a string, a list of strings, or
  # step objects carrying "text" — possibly one itemListElement level down.
  defp collect_steps(value, bodies) do
    value
    |> as_list()
    |> Enum.reduce(bodies, fn
      step, bodies when is_binary(step) ->
        prepend_string(step, bodies)

      step, bodies when is_map(step) ->
        [step | as_list(Map.get(step, "itemListElement"))]
        |> Enum.filter(&is_map/1)
        |> Enum.reduce(bodies, &prepend_string(Map.get(&1, "text"), &2))

      _other, bodies ->
        bodies
    end)
  end

  defp collect_answer(%{"text" => text}, bodies) when is_binary(text), do: prepend_string(text, bodies)
  defp collect_answer(_other, bodies), do: bodies

  defp collect_teaser(item, teasers) do
    type = item |> Map.get("@type", "") |> to_string()
    description = Map.get(item, "description")

    if Enum.any?(@description_types, &String.contains?(type, &1)) and is_binary(description),
      do: [description | teasers],
      else: teasers
  end

  defp prepend_string(value, list) when is_binary(value) and value != "", do: [value | list]
  defp prepend_string(_value, list), do: list

  defp as_list(nil), do: []
  defp as_list(list) when is_list(list), do: list
  defp as_list(value), do: [value]

  # Discourse renders posts client-side but embeds them as JSON in an attribute.
  defp discourse_texts(tree, root) do
    with node when not is_nil(node) <- find_preloaded(tree, root),
         raw when is_binary(raw) <- Tree.attr(tree, node, "data-preloaded"),
         {:ok, preloaded} when is_map(preloaded) <- Jason.decode(raw) do
      preloaded
      |> Enum.filter(fn {key, _value} -> String.starts_with?(key, "topic_") end)
      |> Enum.flat_map(fn {_key, value} -> discourse_posts(value) end)
    else
      _ -> []
    end
  end

  defp find_preloaded(tree, root) do
    tree
    |> Tree.iterdescendants(root, ["div"])
    |> Enum.find(&(Tree.attr(tree, &1, "id") == "data-preloaded"))
  end

  defp discourse_posts(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, %{"post_stream" => %{"posts" => posts}}} when is_list(posts) ->
        for %{"cooked" => cooked} <- posts, is_binary(cooked), do: cooked

      _ ->
        []
    end
  end

  defp discourse_posts(_value), do: []

  # Embedded JSON values may carry (sometimes escaped) HTML markup.
  defp render_embedded(raw) do
    raw = raw |> Text.unescape() |> Text.remove_control_characters()

    case Chushutsu.Tree.Parser.fragment(raw) do
      {:ok, nodes} -> nodes |> Floki.text() |> Text.normalize_space()
      :error -> Text.normalize_space(raw)
    end
  end

  # ## html2txt ------------------------------------------------------------

  @doc """
  Flattens a document to a single line of text.

  Used to size a page for the recall-escalation gate, so its output is compared
  against extraction lengths rather than shown to anyone.
  """
  @spec html_to_txt(Tree.t(), Tree.id(), keyword) :: String.t()
  def html_to_txt(tree, root, opts \\ []) do
    {tree, working} = Tree.deep_copy(tree, root)
    body = Tree.find(tree, working, "body") || working
    tree = if Keyword.get(opts, :clean, true), do: basic_cleaning(tree, body), else: tree

    # space the block boundaries so adjacent runs do not stick together
    tree
    |> Tree.iter(body, @block_elems)
    |> Enum.reduce(tree, fn id, tree ->
      tree
      |> Tree.put_text(id, " " <> (Text.remove_control_characters(Tree.text(tree, id)) || ""))
      |> Tree.put_tail(id, " " <> (Text.remove_control_characters(Tree.tail(tree, id)) || ""))
    end)
    |> Tree.text_content(body)
    |> String.split()
    |> Enum.join(" ")
  end
end
