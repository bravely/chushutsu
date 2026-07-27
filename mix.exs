defmodule Chushutsu.MixProject do
  use Mix.Project

  def project do
    [
      app: :chushutsu,
      version: "0.1.0",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      description: "Web page text and metadata extraction, ported from Python's trafilatura.",
      package: package(),
      docs: [main: "Chushutsu"]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp package do
    [
      licenses: ["Apache-2.0"],
      links: %{"trafilatura" => "https://github.com/adbar/trafilatura"}
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:floki, "~> 0.38"},
      {:html_entities, "~> 0.5"},
      {:html5ever, "~> 0.16", optional: true},
      {:jason, "~> 1.4"},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end
end
