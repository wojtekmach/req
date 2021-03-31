defmodule Req.MixProject do
  use Mix.Project

  def project do
    [
      app: :req,
      version: "0.1.0-dev",
      elixir: "~> 1.11",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      docs: docs()
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
      {:jason, "~> 1.0"},
      {:bypass, "~> 2.1", only: :test},
      {:ex_doc, ">= 0.0.0", only: :docs}
    ]
  end

  defp docs do
    [
      main: "Req",
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
