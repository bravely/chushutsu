defmodule Chushutsu.Core do
  @moduledoc """
  The extraction cascade.

  Each stage only engages when the previous one under-delivered:

    1. the main extractor, including wild-text recovery for short documents
    2. comparison with the generic extractors (readability, justext), skipped in
       fast mode
    3. a baseline rescue over the original, uncleaned tree
    4. recall escalation, when the result still covers little of the page

  Stage 4 exists because a short extraction covering a small share of the page
  usually means the layout is not article-shaped, not that the page is short.
  """

  require Logger

  alias Chushutsu.{Baseline, Deduplication, Document, External, HtmlProcessing}
  alias Chushutsu.{MainExtractor, Metadata, Options, Selectors, Serialize, Settings, Text, Tree}

  @doc """
  Extracts a document without serializing it.

  Returns `{:ok, %Document{}}`, or `{:error, reason}` when the page yielded
  nothing usable.
  """
  @spec bare_extraction(binary | Tree.t(), Options.t()) :: {:ok, Document.t()} | {:error, atom}
  def bare_extraction(input, %Options{} = options) do
    with {:ok, tree, root} <- load(input),
         :ok <- check_html_lang(tree, root, options),
         {:ok, tree, document} <- extract_metadata(tree, root, options),
         {:ok, result} <- run_cascade(tree, root, options),
         :ok <- check_size(result, options),
         :ok <- check_duplicate(result, options) do
      {:ok, build_document(document, result, options)}
    end
  end

  defp load(%Tree{} = tree) do
    case Tree.root(tree) do
      nil -> {:error, :empty_tree}
      root -> {:ok, tree, root}
    end
  end

  defp load(html) when is_binary(html) do
    tree = Tree.parse(html)

    case Tree.root(tree) do
      nil -> {:error, :empty_tree}
      root -> {:ok, tree, root}
    end
  end

  defp load(_other), do: {:error, :unsupported_input}

  # ## Pre-flight checks ---------------------------------------------------

  @lang_attrs ~w(http-equiv property)

  defp check_html_lang(_tree, _root, %Options{lang: nil}), do: :ok

  defp check_html_lang(tree, root, %Options{lang: lang}) do
    metas =
      tree
      |> Tree.iterdescendants(root, ["meta"])
      |> Enum.filter(fn id ->
        Tree.attr(tree, id, "content") != nil and
          Enum.any?(@lang_attrs, &(Tree.attr(tree, id, &1) in ["content-language", "og:locale"]))
      end)

    cond do
      metas == [] -> :ok
      Enum.any?(metas, &declares_language?(tree, &1, lang)) -> :ok
      true -> {:error, :wrong_language}
    end
  end

  defp declares_language?(tree, id, lang) do
    tree
    |> Tree.attr(id, "content", "")
    |> String.downcase()
    |> String.split(~r/[^a-z]+/, trim: true)
    |> Enum.member?(lang)
  end

  defp extract_metadata(tree, _root, %Options{with_metadata: false}), do: {:ok, tree, %Document{}}

  defp extract_metadata(tree, root, options) do
    document = Metadata.extract(tree, root, options)

    cond do
      document.url && MapSet.member?(options.url_blacklist, document.url) ->
        {:error, :blacklisted_url}

      options.only_with_metadata and not (document.date && document.title && document.url) ->
        {:error, :missing_metadata}

      true ->
        {:ok, tree, document}
    end
  end

  # ## The cascade ---------------------------------------------------------

  @doc """
  Runs the four extraction stages, returning the body and comments.

  Exposed for testing; `bare_extraction/2` is the supported entry point.
  """
  @spec run_cascade(Tree.t(), Tree.id(), Options.t()) :: {:ok, map}
  def run_cascade(tree, root, %Options{} = options) do
    forum? = forum_thread_page?(tree, root)

    # With comments off, prune on the raw tree so every stage inherits it.
    {tree, root} =
      if not options.comments and (options.focus == :precision or not forum?),
        do: prune_comments(tree, root),
        else: {tree, root}

    {tree, cleaned, backup} = prepare_tree(tree, root, options)

    {tree, cleaned, comments, forum_posts} = capture_comments(tree, cleaned, backup, options, forum?, root)

    {tree, cleaned} =
      if options.focus == :precision and not forum? do
        # NOT redundant with the raw-tree prune: this runs post-conversion,
        # where <ul id="comments"> has become <list> and now matches the rule
        HtmlProcessing.prune_unwanted_nodes(tree, cleaned, Selectors.remove_comments())
      else
        {tree, cleaned}
      end

    {tree, body, text, length} = MainExtractor.extract_content(tree, cleaned, options)

    {tree, body, text, length} =
      if options.fast,
        do: {tree, body, text, length},
        else: External.compare_extraction(tree, backup, root, body, text, length, options)

    {tree, body, text, length, forum_posts} =
      rescue_with_baseline(tree, root, body, text, length, forum_posts, options)

    {tree, body, text, length, forum_posts} =
      escalate(tree, root, body, text, length, forum_posts, forum?, options)

    {tree, body, text, length} = salvage_forum_posts(tree, body, text, length, forum_posts)

    {:ok,
     %{
       tree: tree,
       body: body,
       text: text,
       length: length,
       comments_body: comments.body,
       comments_text: comments.text,
       comments_length: comments.length
     }}
  end

  # Returns the converted tree alongside a backup taken *after* cleaning but
  # *before* tag conversion — that pre-conversion shape is what readability and
  # jusText expect to be handed.
  defp prepare_tree(tree, root, options) do
    {tree, working} = Tree.deep_copy(tree, root)
    {tree, cleaned} = HtmlProcessing.tree_cleaning(tree, working, options)
    {tree, backup} = Tree.deep_copy(tree, cleaned)
    tree = HtmlProcessing.convert_tags(tree, cleaned, options, options.url)
    {tree, cleaned, backup}
  end

  defp prune_comments(tree, root) do
    {tree, copy} = Tree.deep_copy(tree, root)
    HtmlProcessing.prune_unwanted_nodes(tree, copy, Selectors.remove_comments())
  end

  defp capture_comments(tree, cleaned, _backup, %Options{comments: false}, _forum?, _root) do
    {tree, empty} = Tree.create(tree, "body")
    {tree, cleaned, %{body: empty, text: "", length: 0}, nil}
  end

  defp capture_comments(tree, cleaned, backup, options, forum?, _root) do
    {tree, comments_body, comments_text, comments_length} =
      MainExtractor.extract_comments(tree, cleaned, options)

    if comments_length > 0 and forum? do
      # On a thread forum the "comments" are the posts, so they belong in the
      # body. The capture is kept aside in case the cascade drops them, and the
      # tree is rewound to before the capture removed the section.
      {tree, empty} = Tree.create(tree, "body")
      {tree, restored} = Tree.deep_copy(tree, backup)
      tree = HtmlProcessing.convert_tags(tree, restored, options, options.url)
      {tree, restored, %{body: empty, text: "", length: 0}, comments_body}
    else
      {tree, cleaned, %{body: comments_body, text: comments_text, length: comments_length}, nil}
    end
  end

  # Stage 3: a baseline dump over the original tree.
  defp rescue_with_baseline(tree, root, body, text, length, forum_posts, options) do
    if length < options.min_extracted_size and options.focus != :precision do
      {tree, new_body, new_text, new_length} = Baseline.extract(tree, root)
      # the dump saw the whole page, so missing posts are boilerplate, not lost
      {tree, new_body, new_text, new_length, nil}
    else
      {tree, body, text, length, forum_posts}
    end
  end

  # Stage 4: retry in recall mode, and try justext alongside.
  defp escalate(tree, root, body, text, length, forum_posts, forum?, %Options{focus: :balanced} = options) do
    page_length = tree |> Baseline.html_to_txt(root) |> Text.len()

    if length > 0 and length < Settings.escalation_max_length() and
         length < Settings.escalation_page_share() * page_length do
      do_escalate(tree, root, body, text, length, forum_posts, forum?, options)
    else
      {tree, body, text, length, forum_posts}
    end
  end

  defp escalate(tree, _root, body, text, length, forum_posts, _forum?, _options),
    do: {tree, body, text, length, forum_posts}

  defp do_escalate(tree, root, body, text, length, forum_posts, forum?, options) do
    recall_options = Options.with_focus(options, :recall)

    # Comments are stripped from the escalation input — they duplicate a capture
    # if there was one, and are reader chatter if there wasn't. On a thread
    # forum they stay, because the retry is what rescues the posts.
    {tree, esc_root} = if forum?, do: {tree, root}, else: prune_comments(tree, root)

    {tree, r_body, r_text, r_length} = recall_retry(tree, esc_root, recall_options)

    {tree, j_body, j_text, j_length} =
      if options.fast,
        do: {tree, nil, "", 0},
        else: External.justext_rescue(tree, esc_root, options)

    cond do
      # justext reaches div-buried content the rule retry cannot, but needs a
      # stricter bar because it tends to over-include
      j_length > r_length and j_length > Settings.escalation_justext_ratio() * length ->
        {tree, j_body, j_text, j_length, nil}

      # a result below the pipeline's own minimum is noise
      r_length >= options.min_extracted_size and
          r_length > Settings.escalation_accept_ratio() * length ->
        {tree, r_body, r_text, r_length, nil}

      true ->
        {tree, body, text, length, forum_posts}
    end
  end

  # Re-runs stages 1-2 in recall mode. Deliberately no comment capture, no
  # baseline (it already ran on the full page) and no further escalation.
  defp recall_retry(tree, esc_root, recall_options) do
    {tree, cleaned, backup} = prepare_tree(tree, esc_root, recall_options)
    {tree, body, text, length} = MainExtractor.extract_content(tree, cleaned, recall_options)

    if recall_options.fast do
      {tree, body, text, length}
    else
      External.compare_extraction(tree, backup, esc_root, body, text, length, recall_options)
    end
  rescue
    error ->
      Logger.warning("recall retry failed: #{Exception.message(error)}")
      {tree, nil, "", 0}
  end

  # A gate blocked the cascade from restoring the posts, so append the ones the
  # body is missing.
  defp salvage_forum_posts(tree, body, text, length, nil), do: {tree, body, text, length}

  defp salvage_forum_posts(tree, body, text, length, forum_posts) do
    existing =
      tree
      |> Tree.children(body)
      |> Enum.map(&MainExtractor.elem_text(tree, &1))
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n")

    salvaged =
      tree
      |> Tree.children(forum_posts)
      |> Enum.filter(fn id ->
        post = MainExtractor.elem_text(tree, id)
        post != "" and not String.contains?(existing, post)
      end)

    if salvaged == [] do
      {tree, body, text, length}
    else
      tree = Tree.extend(tree, body, salvaged)
      text = tree |> Tree.itertext(body) |> Enum.join(" ") |> String.trim()
      {tree, body, text, Text.len(text)}
    end
  end

  # Thread-forum pages keep their posts in the very containers the comment rules
  # would prune. Seeded by schema.org DiscussionForumPosting alone; Q&A pages are
  # deliberately not matched, since their answers live outside comment containers.
  @forum_posting ~r/"@type"\s*:\s*"DiscussionForumPosting"|"@type"\s*:\s*\[[^\]]*"DiscussionForumPosting"/

  defp forum_thread_page?(tree, root) do
    tree
    |> Tree.iterdescendants(root, ["script"])
    |> Enum.any?(fn id ->
      Tree.attr(tree, id, "type") == "application/ld+json" and
        (Tree.text(tree, id) || "") =~ @forum_posting
    end)
  end

  # ## Post-flight checks --------------------------------------------------

  defp check_size(result, options) do
    if result.length < options.min_output_size and
         result.comments_length < options.min_output_comm_size,
       do: {:error, :too_short},
       else: :ok
  end

  defp check_duplicate(_result, %Options{dedup: false}), do: :ok

  defp check_duplicate(result, options) do
    text = result.tree |> Tree.itertext(result.body) |> Enum.join(" ") |> Text.trim()

    if Deduplication.duplicate_text?(text, options),
      do: {:error, :duplicate_document},
      else: :ok
  end

  defp build_document(document, result, options) do
    text = Serialize.Text.render(result.tree, result.body, options.formatting)

    comments =
      if options.comments,
        do: Serialize.Text.render(result.tree, result.comments_body, options.formatting),
        else: nil

    %{
      document
      | tree: result.tree,
        body: result.body,
        comments_body: result.comments_body,
        text: text,
        raw_text: if(options.format == :python, do: text, else: result.text),
        comments: comments
    }
  end
end
