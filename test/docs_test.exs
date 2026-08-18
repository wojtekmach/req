defmodule DocsTest do
  use Req.Case, async: true

  @version Mix.Project.config()[:version]

  test "Req.Steps moduledoc lists step modules" do
    {:docs_v1, _, _, _, %{"en" => moduledoc}, _, _} = Code.fetch_docs(Req.Steps)
    [_, section] = String.split(moduledoc, "step modules:", parts: 2)

    listed =
      for [_, name] <- Regex.scan(~r/\* `(Req\.\w+)`/, section) do
        Module.concat([name])
      end

    steps =
      Req.Steps.__default__()
      |> Keyword.values()
      |> Enum.filter(&is_atom/1)

    steps = steps -- [Req.Into]

    assert Enum.sort(listed) == Enum.sort(steps)
  end

  test "README.md links to hexdocs" do
    rc? = match?(["rc" | _], Version.parse!(@version).pre)

    links =
      Regex.scan(~r|^\[[^\]]+\]:[ \t]+(https://hexdocs\.pm/req\S*)$|m, File.read!("README.md"),
        capture: :all_but_first
      )

    assert links != []

    for [link] <- links do
      if rc? do
        assert String.starts_with?(link, "https://hexdocs.pm/req/#{@version}/"),
               "README.md has #{link} which should link to version #{@version}"
      else
        refute link =~ ~r|^https://hexdocs\.pm/req/\d|,
               "README.md has #{link} which should be unversioned"
      end
    end
  end

  @tag skip: Version.parse!(@version).pre == ["dev"]
  test "version" do
    requirements =
      Regex.scan(~r/\{:req, "(~> [^"]+)"/, File.read!("README.md"), capture: :all_but_first)

    assert requirements != []

    for [requirement] <- requirements do
      assert Version.match?(@version, requirement),
             ~s|README.md has {:req, "#{requirement}"} which does not match version #{@version}|
    end
  end
end
