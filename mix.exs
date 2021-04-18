defmodule Req.MixProject do
  use Mix.Project

  def project do
    [
      app: :req,
      version: "0.1.0-dev",
      elixir: "~> 1.11",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      docs: docs(),
      xref: [
        exclude: [
          NimbleCSV.RFC4180
        ]
      ],
      lockfile: "lib/mix.lock"
    ]
  end

  def application do
    [
      mod: {Req.Application, []},
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:finch, "~> 0.6.0"},
      {:mint, github: "elixir-mint/mint", override: true},
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
      source_url: "https://github.com/wojtekmach/req",
      source_ref: "main",
      groups_for_functions: [
        "High-level API": &(&1[:api] == :high_level),
        "Low-level API": &(&1[:api] == :low_level),
        "Request steps": &(&1[:api] == :request),
        "Response steps": &(&1[:api] == :response),
        "Error steps": &(&1[:api] == :error)
      ]
    ]
  end
end
