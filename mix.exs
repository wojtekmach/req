defmodule Req.MixProject do
  use Mix.Project

  @version "0.3.0-dev"
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
      aliases: [
        "test.all": ["test --include integration"]
      ],
      preferred_cli_env: [
        "test.all": :test,
        docs: :docs,
        "hex.publish": :docs
      ],
      xref: [
        exclude: [
          NimbleCSV.RFC4180,
          Plug.Test,
          :brotli
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
      {:finch, "~> 0.9.0 or ~> 0.10.0 or ~> 0.11.0"},
      {:mime, "~> 1.6 or ~> 2.0"},
      {:jason, "~> 1.0"},
      {:nimble_csv, "~> 1.0", optional: true},
      {:plug, "~> 1.0", optional: true},
      {:brotli, "~> 0.3.1", optional: true},
      {:ezstd, "~>1.0", optional: true},
      {:bypass, "~> 2.1", only: :test},
      {:ex_doc, ">= 0.0.0", only: :docs}
    ]
  end

  defp docs do
    [
      main: "readme",
      source_url: @source_url,
      source_ref: "v#{@version}",
      groups_for_functions: [
        "Request steps": &(&1[:step] == :request),
        "Response steps": &(&1[:step] == :response),
        "Error steps": &(&1[:step] == :error)
      ],
      extras: [
        "README.md",
        "CHANGELOG.md"
      ]
    ]
  end
end
