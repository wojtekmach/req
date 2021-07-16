defmodule Req.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/wojtekmach/req"

  def project do
    [
      app: :req,
      version: @version,
      elixir: "~> 1.11",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      package: package(),
      docs: docs(),
      xref: [
        exclude: [
          NimbleCSV.RFC4180
        ]
      ]
    ]
  end

  def application do
    [
      mod: {Req.Application, []},
      extra_applications: [:logger]
    ]
  end

  defp package do
    [
      description:
        "Req is an HTTP client with a focus on ease of use and composability, built on top of Finch.",
      licenses: ["Apache-2.0"],
      links: %{
        "GitHub" => @source_url
      }
    ]
  end

  defp deps do
    [
      {:finch, "~> 0.6.0"},
      {:mime, "~> 1.6"},
      {:jason, "~> 1.0"},
      {:nimble_csv, "~> 1.0", optional: true},
      {:bypass, "~> 2.1", only: :test},
      {:ex_doc, ">= 0.0.0", only: :docs}
    ]
  end

  defp docs do
    [
      main: "Req",
      source_url: @source_url,
      source_ref: "v#{@version}",
      groups_for_functions: [
        "High-level API": &(&1[:api] == :high_level),
        "Low-level API": &(&1[:api] == :low_level),
        "Request steps": &(&1[:api] == :request),
        "Response steps": &(&1[:api] == :response),
        "Error steps": &(&1[:api] == :error)
      ],
      extras: [
        "CHANGELOG.md"
      ]
    ]
  end
end
