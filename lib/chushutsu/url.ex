defmodule Chushutsu.URL do
  @moduledoc "The small slice of URL handling the extractor needs: base URLs and link absolutization."

  @doc "Scheme and host of a URL, without path or query."
  @spec base_url(String.t() | nil) :: String.t() | nil
  def base_url(nil), do: nil

  def base_url(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host} when is_binary(scheme) and is_binary(host) ->
        "#{scheme}://#{host}"

      _ ->
        nil
    end
  end

  @doc "Hostname of a URL, or `nil` when it has none."
  @spec host(String.t() | nil) :: String.t() | nil
  def host(nil), do: nil
  def host(url), do: URI.parse(url).host

  @doc """
  Resolves a possibly-relative link against a base URL.

  Absolute links and non-URL values (template placeholders, `mailto:`) are left
  untouched; protocol-relative links inherit the base scheme.
  """
  @spec absolutize(String.t(), String.t() | nil) :: String.t()
  def absolutize(target, nil), do: target

  def absolutize("//" <> _ = target, base) do
    case URI.parse(base) do
      %URI{scheme: scheme} when is_binary(scheme) -> scheme <> ":" <> target
      _ -> target
    end
  end

  def absolutize("http" <> _ = target, _base), do: target
  def absolutize("{" <> _ = target, _base), do: target
  def absolutize("#" <> _ = target, _base), do: target

  def absolutize(target, base) do
    if String.contains?(target, ":") and not String.starts_with?(target, "/") do
      # an unknown scheme (mailto:, tel:, javascript:) — nothing to resolve
      target
    else
      base |> URI.merge(target) |> URI.to_string()
    end
  rescue
    _ -> target
  end
end
