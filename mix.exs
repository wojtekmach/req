defmodule Req.MixProject do
  use Mix.Project

  @version "0.7.0-dev"
  @source_url "https://github.com/wojtekmach/req"

  def project do
    [
      app: :req,
      version: @version,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      package: package(),
      docs: docs(),
      aliases: aliases(),
      elixirc_paths: elixirc_paths(Mix.env()),
      elixirc_options: [
        no_warn_undefined: [
          NimbleCSV.RFC4180,
          Plug.Conn,
          Plug.HTML,
          Plug.Test,
          :brotli,
          :zstd
        ]
      ]
    ]
  end

  def application do
    [
      mod: {Req.Application, []},
      extra_applications: extra_applications(Mix.env())
    ]
  end

  def cli do
    [
      preferred_envs: [
        "test.all": :test,
        "test.adapters": :test,
        docs: :docs,
        "hex.publish": :docs
      ]
    ]
  end

  defp package do
    [
      description: "Req is a batteries-included HTTP client for Elixir.",
      licenses: ["Apache-2.0"],
      links: %{
        "GitHub" => @source_url,
        "Changelog" => "https://hexdocs.pm/req/changelog.html"
      }
    ]
  end

  defp aliases do
    [
      "test.all": ["test --include integration"],
      "test.adapters": &test_adapters/1
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp extra_applications(:test), do: [:logger, :inets]
  defp extra_applications(_), do: [:logger]

  defp test_adapters(_args) do
    for adapter <- ~w(finch httpc) do
      {_, status} =
        System.cmd("mix", ["test.all"],
          env: [{"REQ_ADAPTER", adapter}],
          into: IO.stream(:stdio, :line)
        )

      if status != 0 do
        exit({:shutdown, status})
      end
    end
  end

  defp deps do
    [
      {:finch, "~> 0.21.0 or ~> 0.22.0", finch_opts()},
      {:mime, "~> 2.0.6 or ~> 2.1"},
      {:jason, "~> 1.0"},
      {:nimble_csv, "~> 1.0", optional: true},
      {:plug, "~> 1.0", [optional: true] ++ plug_opts()},
      {:brotli, "~> 0.3.1", optional: true},
      {:aws_signature, "~> 0.3.2", only: :test},
      {:bypass, "~> 2.1", only: :test},
      {:ex_doc, ">= 0.0.0", only: :docs, warn_if_outdated: true},
      {:bandit, "~> 1.0", only: :test},
      {:castore, "~> 1.0", only: :test}
    ]
  end

  defp finch_opts do
    cond do
      path = System.get_env("FINCH_PATH") ->
        [path: path]

      ref = System.get_env("FINCH_REF") ->
        [github: "sneako/finch", ref: ref]

      true ->
        []
    end
  end

  defp plug_opts do
    cond do
      path = System.get_env("PLUG_PATH") ->
        [path: path, override: true]

      ref = System.get_env("PLUG_REF") ->
        [github: "elixir-plug/plug", ref: ref, override: true]

      true ->
        []
    end
  end

  defp docs do
    [
      main: "readme",
      source_url: @source_url,
      source_ref: "v#{@version}",
      groups_for_docs: [
        Types: &(&1[:kind] == :type),
        Callbacks: &(&1[:kind] == :callback),
        "Request Steps": &(&1[:step] == :request),
        "Response Steps": &(&1[:step] == :response),
        "Error Steps": &(&1[:step] == :error),
        Functions:
          &(&1[:kind] == :function and &1[:type] not in [:request, :mock, :async, :assigns]),
        "Functions (Making Requests)": &(&1[:type] == :request),
        "Functions (Async Response)": &(&1[:type] == :async),
        "Functions (Mocks & Stubs)": &(&1[:type] == :mock)
      ],
      extras: [
        "README.md",
        "CHANGELOG.md"
      ],
      skip_code_autolink_to: [
        "Req.Test.stub/1",
        "Req.Utils.aws_sigv4_url/1",
        "Req.update/2"
      ]
    ]
  end

  def legacy_headers_as_lists? do
    Application.get_env(:req, :legacy_headers_as_lists, false)
  end
end
