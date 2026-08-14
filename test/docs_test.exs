defmodule DocsTest do
  use Req.Case, async: true

  @version Mix.Project.config()[:version]

  @tag skip: Version.parse!(@version).pre != []
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
