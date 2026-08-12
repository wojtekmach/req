defmodule Req.CSV do
  @moduledoc """
  CSV decoding using [nimble_csv].

  `Req.Decode` can use this module for `.csv` and `text/csv` responses when the `:csv`
  decoder is enabled via the `:decoders` option.

  [nimble_csv]: https://hex.pm/packages/nimble_csv

  ## Examples

      Req.get!(url, decoders: [:csv]).body
      #=> [["x", "y"], ["1", "2"], ["3", "4"]]

  `Req.CSV` does NOT currently do streaming decoding:

      Req.stream(
        url,
        nil,
        fn data, _resp, acc ->
          IO.inspect(data)
          {:cont, acc}
        end,
        decoders: [:csv]
      )
      # Output: "x,y\\r\\n"
      # Output: "1,2\\r\\n"
      # Output: "3,4\\r\\n"
  """

  @doc false
  def decode(string) do
    {:ok, NimbleCSV.RFC4180.parse_string(string, skip_headers: false)}
  end

  @doc false
  def decode_init(:buffer) do
    {:buffer, ""}
  end

  @doc false
  def decode_init(:stream) do
    :stream
  end

  @doc false
  def decode_chunk({:buffer, buffer}, data) do
    {:ok, data, {:buffer, [buffer | data]}}
  end

  @doc false
  def decode_chunk(:stream, data) do
    {:ok, data, :stream}
  end

  @doc false
  def decode_finish({:buffer, buffer}) do
    decode(IO.iodata_to_binary(buffer))
  end

  @doc false
  def decode_finish(:stream) do
    {:ok, nil}
  end

  @doc false
  def decode_close(_state) do
    :ok
  end
end
