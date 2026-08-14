defmodule Req.ZIPTest do
  use Req.Case, async: true

  test "decode" do
    files = [{~c"foo.txt", "bar"}]
    {:ok, {_name, zip}} = :zip.create(~c"a.zip", files, [:memory])

    assert Req.ZIP.decode(zip) == {:ok, files}
  end

  test "invalid" do
    assert Req.ZIP.decode("invalid") ==
             {:error, %Req.ArchiveError{format: :zip, data: "invalid", reason: nil}}
  end
end
