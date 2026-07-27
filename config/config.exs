import Config

# html5ever follows the HTML5 parsing spec, which matters for the malformed
# real-world markup the extractor is aimed at.
config :floki, :html_parser, Floki.HTMLParser.Html5ever
