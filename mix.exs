defmodule Req.MixProject do
  use Mix.Project

  @version "0.5.8"
  @source_url "https://github.com/wojtekmach/req"

  def project do
    [
      app: :req,
      version: @version,
      elixir: "~> 1.13",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      package: package(),
      docs: docs(),
      aliases: aliases(),
      xref: [
        exclude: [
          NimbleCSV.RFC4180,
          Plug.Test,
          Plug.Conn,
          :brotli,
          :ezstd
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

  def cli do
    [
      preferred_envs: [
        ci: :test,
        "test.all": :test,
        docs: :docs,
        "hex.publish": :docs
      ]
    ]
  end

  defp aliases do
    [
      "test.all": ["test --include integration"],
      ci: &ci/1
    ]
  end

  defp ci(args) do
    strict? =
      case args do
        [] -> true
        ["--relaxed"] -> false
      end

    tasks =
      if strict? do
        [
          "deps.get --no-archives-check --check-locked",
          "deps.unlock --check-unused",
          "format --check-formatted",
          "compile --no-optional-deps --warnings-as-errors",
          "compile --warnings-as-errors",
          "test --warnings-as-errors"
        ]
      else
        [
          "deps.get",
          "test"
        ]
      end

    runner = System.get_env("GITHUB_ACTIONS") && :github

    for task <- tasks do
      [name | args] = OptionParser.split(task)
      with_task_title(task, runner, fn -> Mix.Task.rerun(name, args) end)
    end
  end

  defp with_task_title(task, :github, fun) do
    IO.puts("::group::Run mix #{task}")
    fun.()
    IO.puts("::endgroup::")
  end

  defp with_task_title(task, nil, fun) do
    IO.puts(">> Run mix #{task}")
    fun.()
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

  defp deps do
    [
      {:finch, "~> 0.17", finch_opts()},
      {:mime, "~> 2.0.6 or ~> 2.1"},
      {:jason, "~> 1.0"},
      {:nimble_csv, "~> 1.0", optional: true},
      {:plug, "~> 1.0", [optional: true] ++ plug_opts()},
      {:brotli, "~> 0.3.1", optional: true},
      {:ezstd, "~> 1.0", optional: true},
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
        Functions: &(&1[:kind] == :function and &1[:type] not in [:request, :mock, :async]),
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
        "Req.update/2"
      ]
    ]
  end

  def legacy_headers_as_lists? do
    Application.get_env(:req, :legacy_headers_as_lists, false)
  end
end
