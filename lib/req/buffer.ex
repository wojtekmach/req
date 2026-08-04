defmodule Req.Buffer do
  @moduledoc false

  defstruct iodata: [], decoded: :unset

  def to_binary(%Req.Buffer{iodata: iodata}) do
    IO.iodata_to_binary(iodata)
  end

  def body(%Req.Buffer{decoded: {:ok, term}}), do: term
  def body(%Req.Buffer{} = buffer), do: to_binary(buffer)
end
