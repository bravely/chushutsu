defmodule Chushutsu.Selectors do
  @moduledoc """
  Trafilatura's content and boilerplate rules, expressed as predicates.

  Upstream these are lxml `XPath` objects leaning on the EXSLT `re:test`
  extension. Rather than ship an XPath engine, each expression is translated into
  a plain predicate over a node — faster, and it keeps the rules readable as what
  they actually are: a hand-tuned vocabulary of class/id tokens.

  Two XPath subtleties are preserved deliberately, because the upstream
  heuristics are calibrated around them:

    * `@id|@class` builds a node-set that `re:test` coerces with `string()`,
      which takes only the **first attribute in source order** — not both. See
      `Chushutsu.Tree.first_attr/3`.
    * `translate(@class, 'CM', 'cm')` lower-cases *only* the listed letters, so
      `MAIN-CONTENT` does not match where `Main-Content` does.

  Each rule is `{tags_or_nil, predicate}`: `nil` tags means any element.
  """

  alias Chushutsu.Tree

  @type rule :: {[String.t()] | nil, (Tree.t(), Tree.id() -> boolean)}

  # ## Content-area vocabulary ---------------------------------------------

  @article_content_id ~r/(?:entry|article|art)-content|article__content|article(?:-|__)?body|articleBody|body-text/

  @article_content_class ~r/post[-_]text|post-body|post-?entry|post[-_]?content|postContent|post_inner_wrapper|article-?text|articleText|(?:entry|page|text|article|art)-content|article__content|article(?:-|__)?body|articleBody|ArticleContent|body-text|article__container/

  @story_id ~r/^primary|story-body/

  @story_class ~r/^article |post-bodycopy|story-?content|(?:theme|blog|section|single)-content|single-post|main-column|wpb_text_column|story-body|field-body/

  @main_content_id ~r/content-main|content-body|contentBody/
  @main_content_class ~r/content[-_]main|content(?:-|__)body/

  @content_tags ~w(article div main section)

  @doc """
  Ordered rules locating the main content area; the first that hits wins.

  Each rule yields the first matching element in document order. Upstream some
  of these are written `.//*[cond][1]` (first match *per parent*) and the caller
  then takes the first result — which is the same element, since the globally
  first match is necessarily the first match under its own parent.
  """
  @spec content() :: [rule]
  def content do
    [
      {@content_tags,
       fn tree, id ->
         Tree.attr(tree, id, "class") in ["post", "entry"] or
           Tree.attr(tree, id, "itemprop") == "articleBody" or
           Tree.attr(tree, id, "id") == "articleContent" or
           matches?(tree, id, "id", @article_content_id) or
           matches?(tree, id, "class", @article_content_class)
       end},
      {["article"], fn _tree, _id -> true end},
      {@content_tags,
       fn tree, id ->
         Tree.attr(tree, id, "role") == "article" or
           Tree.attr(tree, id, "id") in ["article", "story"] or
           Tree.attr(tree, id, "class") in ~w(postarea art-postcontent text cell story) or
           matches?(tree, id, "id", @story_id) or
           matches?(tree, id, "class", ~r/fulltext/i) or
           matches?(tree, id, "class", @story_class)
       end},
      {@content_tags,
       fn tree, id ->
         Tree.attr(tree, id, "id") == "content" or
           Tree.attr(tree, id, "class") == "content" or
           matches?(tree, id, "id", @main_content_id) or
           matches?(tree, id, "class", @main_content_class) or
           translated_contains?(tree, id, "id", "CM", "main-content") or
           translated_contains?(tree, id, "class", "CM", "main-content") or
           translated_contains?(tree, id, "class", "CP", "page-content")
       end},
      {["article", "div", "section", "main"],
       fn tree, id ->
         Tree.tag(tree, id) == "main" or
           starts_with?(tree, id, "class", "main") or
           starts_with?(tree, id, "id", "main") or
           starts_with?(tree, id, "role", "main")
       end}
    ]
  end

  # ## Comments ------------------------------------------------------------

  @doc "Ordered rules locating a comment section; the first that hits wins."
  @spec comments() :: [rule]
  def comments do
    [
      {~w(div list section),
       fn tree, id ->
         first_matches?(tree, id, ["id", "class"], ~r/comment-?list/) or
           matches?(tree, id, "class", ~r/comment-page|comments-content|post-comments/)
       end},
      {~w(div section list),
       fn tree, id ->
         first_matches?(tree, id, ["id", "class"], ~r/^comment[s-]/) or
           matches?(tree, id, "class", ~r/^Comments|article-comments/)
       end},
      {~w(div section list), fn tree, id -> matches?(tree, id, "id", ~r/^(?:comol|disqus_thread|dsq-comments)/) end},
      {~w(div section),
       fn tree, id ->
         starts_with?(tree, id, "id", "social") or
           contains?(tree, id, "class", "comment")
       end}
    ]
  end

  @doc "Containers to prune when comments are being excluded from the body."
  @spec remove_comments() :: [rule]
  def remove_comments do
    [
      {~w(div list section details),
       fn tree, id ->
         matches?(tree, id, "id", ~r/^(?:[Cc]omment|comol|disqus_thread|dsq-comments)/) or
           matches?(tree, id, "class", ~r/^[Cc]omment|(?:article|post)-comments/)
       end}
    ]
  end

  @doc "Sections stripped from a comment subtree before its content is read."
  @spec comments_discard() :: [rule]
  def comments_discard do
    [
      {~w(div section), fn tree, id -> starts_with?(tree, id, "id", "respond") end},
      {~w(cite quote), fn _tree, _id -> true end},
      {nil,
       fn tree, id ->
         Tree.attr(tree, id, "class") == "comments-title" or
           contains?(tree, id, "style", "display:none") or
           matches?(tree, id, "class", ~r/comments-title|nocomments|-reply-|message|signin/) or
           first_matches?(tree, id, ["id", "class"], ~r/^reply-|akismet/)
       end}
    ]
  end

  # ## Boilerplate discard vocabulary --------------------------------------

  # Tokens checked against BOTH id and class.
  @discard_both "^shar|social|viral|newsletter|syndication|tags|sidebar|banner|bread-?crumb|button|author"

  # Tokens checked against id only: legacy per-site markers, footers, nav, paywalls.
  @discard_id_only "^(?:jp-|dpsp-content)|bmdh|footer|Footer|share|Share|nav|Nav|menu|related|message-container|premium"

  # Tokens checked against class only: nav, ads, bylines, share widgets, consent,
  # related-content teasers, UI chrome and a handful of single-site classes.
  @discard_class_only "^(?:nav|post-nav|ZendeskForm)|subnav|avigation|navbar|navbox|menu|bar| ad |-ad-|outbrain|taboola|criteo|paid-?content|widget|footer|Footer|byline|Byline|share-|sociable|embedded|embed|tag-list|consent|modal-content|permission|elated|next-|-stories|most-popular|meta|rating|attachment|timestamp|user-info|user-profile|-icon|article-infos|message-container|slide|viewport|overlay|options|expand|obfuscated|blurred|mol-factbox|yin|zlylin|nfoline"

  @discard_id Regex.compile!(@discard_both <> "|" <> @discard_id_only)
  @discard_class Regex.compile!(@discard_both <> "|" <> @discard_class_only)

  @discard_hidden_class ~r/^hide-|comments-title|nocomments|-reply-|message|akismet|suggest-links|-hide-|hide-print| hidden| hide|noprint|notloaded/

  @block_tags ~w(div item list p section span)

  @doc "Boilerplate sections removed from every candidate subtree."
  @spec overall_discard() :: [rule]
  def overall_discard do
    [
      {@block_tags,
       fn tree, id ->
         # kept first-attribute-only on purpose: pages *about* cookies carry
         # the token on real content, and testing both attributes over-discards
         Tree.attr(tree, id, "data-lp-replacement-content") != nil or
           translated_contains?(tree, id, "role", "N", "nav") or
           contains?(tree, id, "data-component", "MostPopularStories") or
           first_matches?(tree, id, ["id", "class"], ~r/cookie/) or
           matches?(tree, id, "id", @discard_id) or
           matches?(tree, id, "class", @discard_class)
       end},
      {nil,
       fn tree, id ->
         Tree.attr(tree, id, "class") == "comments-title" or
           first_starts_with?(tree, id, ["id", "class"], "reply-") or
           first_matches?(tree, id, ["id", "style"], ~r/hidden/) or
           contains?(tree, id, "style", "display:none") or
           contains?(tree, id, "style", "display: none") or
           matches?(tree, id, "id", ~r/reader-comments|akismet/) or
           matches?(tree, id, "class", @discard_hidden_class) or
           Tree.attr(tree, id, "aria-hidden") == "true"
       end}
    ]
  end

  @doc "Teaser blocks — dropped except on the last-resort recovery path."
  @spec teaser_discard() :: [rule]
  def teaser_discard do
    [
      {@block_tags,
       fn tree, id ->
         translated_contains?(tree, id, "id", "T", "teaser") or
           translated_contains?(tree, id, "class", "T", "teaser")
       end}
    ]
  end

  @doc "Extra sections dropped only when favouring precision."
  @spec precision_discard() :: [rule]
  def precision_discard do
    [
      {["header"], fn _tree, _id -> true end},
      {@block_tags,
       fn tree, id ->
         # whole class token, not a substring: matching `link` loosely also
         # dropped permalink/headline-link and similar real content
         first_contains?(tree, id, ["id", "class"], "bottom") or
           first_matches?(tree, id, ["id", "class"], ~r/(^|\s)link(\s|$)/) or
           contains?(tree, id, "style", "border")
       end}
    ]
  end

  @doc "Caption blocks, dropped when images are not being kept."
  @spec image_discard() :: [rule]
  def image_discard do
    [
      {@block_tags,
       fn tree, id ->
         contains?(tree, id, "id", "caption") or contains?(tree, id, "class", "caption")
       end}
    ]
  end

  # ## Metadata ------------------------------------------------------------

  @author_tags ~w(a address div link p span strong h3 h4)

  @doc "Ordered rules for locating an author byline, most specific first."
  @spec author() :: [rule]
  def author do
    [
      {@author_tags ++ ["author"],
       fn tree, id ->
         Tree.tag(tree, id) == "author" or
           Tree.attr(tree, id, "rel") in ["author", "me"] or
           Tree.attr(tree, id, "id") == "author" or
           Tree.attr(tree, id, "class") == "author" or
           Tree.attr(tree, id, "itemprop") == "author name" or
           Tree.attr(tree, id, "data-testid") in ["AuthorCard", "AuthorURL"] or
           matches?(tree, id, "class", ~r/author-?name|AuthorName|authorName/)
       end},
      {@author_tags,
       fn tree, id ->
         Tree.attr(tree, id, "class") in ~w(byline username byl BBL) or
           contains?(tree, id, "itemprop", "author") or
           matches?(tree, id, "id", ~r/author|zuozhe|bianji|xiaobian/) or
           matches?(
             tree,
             id,
             "class",
             ~r/author|channel-name|zuozhe|bianji|xiaobian|submitted-by|posted-by|journalist-name/
           )
       end},
      {nil,
       fn tree, id ->
         contains?(tree, id, "data-component", "Byline") or
           contains?(tree, id, "itemprop", "author") or
           matches?(tree, id, "id", ~r/[Aa]uthor/) or
           matches?(tree, id, "class", ~r/[Aa]uthor|screenname|writer|[Bb]yline/)
       end}
    ]
  end

  @doc "Regions pruned before an author byline is searched for."
  @spec author_discard() :: [rule]
  def author_discard do
    [
      {~w(a div section span),
       fn tree, id ->
         Tree.attr(tree, id, "id") == "comments" or
           Tree.attr(tree, id, "class") in ~w(comments title date) or
           matches?(tree, id, "id", ~r/^comments|comment-?list|ProductReviews/) or
           matches?(
             tree,
             id,
             "class",
             ~r/^[Cc]omments|commentlist|comments-list|sidebar|is-hidden|quote|embedly-instagram|article-(?:share|support)|print|category|meta-date|meta-reviewer/
           ) or
           contains?(tree, id, "data-component", "Figure")
       end},
      {~w(time figure), fn _tree, _id -> true end}
    ]
  end

  @doc "Ordered rules for locating a page title."
  @spec title() :: [rule]
  def title do
    [
      {~w(h1 h2),
       fn tree, id ->
         matches?(tree, id, "class", ~r/(?:post-|entry-|article-|post__)title|headline/) or
           contains?(tree, id, "id", "headline") or
           contains?(tree, id, "itemprop", "headline")
       end},
      {nil, fn tree, id -> Tree.attr(tree, id, "class") in ["entry-title", "post-title"] end},
      {~w(h1 h2 h3),
       fn tree, id ->
         contains?(tree, id, "class", "title") or contains?(tree, id, "id", "title")
       end}
    ]
  end

  @doc """
  Ordered rules for category links.

  Each returns the *container*; the caller collects `a[href]` beneath it.
  """
  @spec categories() :: [rule]
  def categories do
    [
      {["div"],
       fn tree, id ->
         matches?(tree, id, "class", ~r/^(?:post-?info|post-?meta|meta|entry-meta|entry-info|entry-utility)/) or
           starts_with?(tree, id, "id", "postpath")
       end},
      {["p"],
       fn tree, id ->
         starts_with?(tree, id, "class", "postmeta") or
           starts_with?(tree, id, "class", "entry-categories") or
           Tree.attr(tree, id, "class") == "postinfo" or
           Tree.attr(tree, id, "id") == "filedunder"
       end},
      {["footer"],
       fn tree, id ->
         starts_with?(tree, id, "class", "entry-meta") or starts_with?(tree, id, "class", "entry-footer")
       end},
      {~w(li span),
       fn tree, id ->
         Tree.attr(tree, id, "class") in ~w(post-category postcategory entry-category) or
           contains?(tree, id, "class", "cat-links")
       end},
      {["header"], fn tree, id -> Tree.attr(tree, id, "class") == "entry-header" end},
      {["div"], fn tree, id -> Tree.attr(tree, id, "class") in ["row", "tags"] end}
    ]
  end

  @doc "Ordered rules for tag links; like `categories/0`, these return containers."
  @spec tags() :: [rule]
  def tags do
    [
      {["div"], fn tree, id -> Tree.attr(tree, id, "class") == "tags" end},
      {["p"], fn tree, id -> starts_with?(tree, id, "class", "entry-tags") end},
      {["div"],
       fn tree, id ->
         Tree.attr(tree, id, "class") in ~w(row jp-relatedposts entry-utility) or
           matches?(tree, id, "class", ~r/^(?:tag|postmeta|meta)/)
       end},
      {nil,
       fn tree, id ->
         Tree.attr(tree, id, "class") == "entry-meta" or
           contains?(tree, id, "class", "topics") or
           contains?(tree, id, "class", "tags-links")
       end}
    ]
  end

  # ## Rule application ----------------------------------------------------

  @doc "Every element under `root` (inclusive) matching the rule, in document order."
  @spec select(Tree.t(), Tree.id(), rule) :: [Tree.id()]
  def select(tree, root, {tags, predicate}) do
    tree
    |> Tree.iterdescendants(root, tags)
    |> Enum.filter(&predicate.(tree, &1))
  end

  @doc "The first element under `root` matching the rule, or `nil`."
  @spec select_first(Tree.t(), Tree.id(), rule) :: Tree.id() | nil
  def select_first(tree, root, {tags, predicate}) do
    tree
    |> Tree.iterdescendants(root, tags)
    |> Enum.find(&predicate.(tree, &1))
  end

  @doc "All elements matching any rule in the list."
  @spec select_all(Tree.t(), Tree.id(), [rule]) :: [Tree.id()]
  def select_all(tree, root, rules), do: Enum.flat_map(rules, &select(tree, root, &1))

  # ## Attribute predicates ------------------------------------------------

  defp matches?(tree, id, name, regex) do
    case Tree.attr(tree, id, name) do
      nil -> false
      value -> Regex.match?(regex, value)
    end
  end

  defp first_matches?(tree, id, names, regex) do
    case Tree.first_attr(tree, id, names) do
      nil -> false
      value -> Regex.match?(regex, value)
    end
  end

  defp contains?(tree, id, name, needle) do
    case Tree.attr(tree, id, name) do
      nil -> false
      value -> String.contains?(value, needle)
    end
  end

  defp first_contains?(tree, id, names, needle) do
    case Tree.first_attr(tree, id, names) do
      nil -> false
      value -> String.contains?(value, needle)
    end
  end

  defp starts_with?(tree, id, name, prefix) do
    case Tree.attr(tree, id, name) do
      nil -> false
      value -> String.starts_with?(value, prefix)
    end
  end

  defp first_starts_with?(tree, id, names, prefix) do
    case Tree.first_attr(tree, id, names) do
      nil -> false
      value -> String.starts_with?(value, prefix)
    end
  end

  # XPath's translate() with a two-letter map, e.g. translate(@class, 'CM', 'cm'):
  # only the listed characters are folded, so `MAIN-CONTENT` stays unmatched.
  defp translated_contains?(tree, id, name, uppercase, needle) do
    case Tree.attr(tree, id, name) do
      nil ->
        false

      value ->
        uppercase
        |> String.graphemes()
        |> Enum.reduce(value, &String.replace(&2, &1, String.downcase(&1)))
        |> String.contains?(needle)
    end
  end
end
