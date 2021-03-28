defmodule Req.MixProject do
  use Mix.Project

  def project do
    [
      app: :req,
      version: "0.1.0",
      elixir: "~> 1.12-dev",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      mod: {Req.Application, []},
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:finch, "~> 0.6.0"},
      {:mint, github: "elixir-mint/mint", override: true},
      {:jason, "~> 1.0"},
      {:bypass, "~> 2.1", only: :test}
    ]
  end
end
