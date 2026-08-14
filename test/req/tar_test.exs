defmodule Req.TarTest do
  use Req.Case, async: true

  test "decode" do
    files = [{~c"foo.txt", "bar"}]

    assert Req.Tar.decode(create_tar(files)) == {:ok, files}
    assert Req.Tar.decode(create_tar(files, compressed: true)) == {:ok, files}
  end

  test "invalid" do
    assert Req.Tar.decode("invalid") ==
             {:error, %Req.ArchiveError{format: :tar, data: "invalid", reason: :eof}}
  end
end
