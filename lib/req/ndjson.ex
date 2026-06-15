defmodule Req.NDJSON.DecodeError do
  # The exception raised on invalid NDJSON, mirroring `JSON.DecodeError`.
  @moduledoc false
  defexception [:message, :offset, :data]
end

defmodule Req.NDJSON do
  # Decodes newline-delimited JSON (https://github.com/ndjson/ndjson-spec).
  @moduledoc false

  @behaviour Req.StreamDecoder

  if System.otp_release() >= "27" do
    @json :json
  else
    @json :elixir_json
  end

  @impl true
  def decode(binary) when is_binary(binary) do
    with {:ok, events, state} <- stream_chunk(binary, stream_start(nil)),
         {:ok, rest, _state} <- stream_finish(state) do
      {:ok, events ++ rest}
    else
      {:error, exception, _state} -> {:error, exception}
    end
  end

  @doc false
  def stream(binary) when is_binary(binary) do
    Stream.transform(
      [binary],
      fn -> stream_start(nil) end,
      fn data, state ->
        case stream_chunk(data, state) do
          {:ok, events, state} -> {events, state}
          {:error, exception, _state} -> raise exception
        end
      end,
      fn state ->
        case stream_finish(state) do
          {:ok, events, state} -> {events, state}
          {:error, exception, _state} -> raise exception
        end
      end,
      fn _state -> :ok end
    )
  end

  @impl true
  def stream_start(_resp) do
    :buffering
  end

  @impl true
  def stream_chunk(data, state) do
    case state do
      :buffering ->
        start(data, [])

      {:continue, cont} ->
        continue(@json.decode_continue(data, cont), [])
    end
  catch
    :error, {:invalid_byte, byte} ->
      offset = offset(__STACKTRACE__)

      exception = %Req.NDJSON.DecodeError{
        message: "invalid byte #{byte} at position (byte offset) #{offset}",
        data: data,
        offset: offset
      }

      {:error, exception, state}

    :error, {:unexpected_sequence, bytes} ->
      offset = offset(__STACKTRACE__)

      exception = %Req.NDJSON.DecodeError{
        message: "unexpected sequence #{inspect(bytes)} at position (byte offset) #{offset}",
        data: data,
        offset: offset
      }

      {:error, exception, state}
  end

  @impl true
  def stream_finish(state) do
    case state do
      :buffering ->
        {:ok, [], :buffering}

      {:continue, cont} ->
        {value, :ok, ""} = @json.decode_continue(:end_of_input, cont)
        {:ok, [value], :buffering}
    end
  catch
    :error, :unexpected_end ->
      exception = %Req.NDJSON.DecodeError{
        message: "unexpected end of JSON binary at position (byte offset) 0",
        data: nil,
        offset: 0
      }

      {:error, exception, state}
  end

  defp start(data, events) do
    if String.trim(data) == "" do
      {:ok, Enum.reverse(events), :buffering}
    else
      continue(@json.decode_start(data, :ok, %{}), events)
    end
  end

  defp continue({:continue, cont}, events) do
    {:ok, Enum.reverse(events), {:continue, cont}}
  end

  defp continue({value, :ok, rest}, events) do
    start(rest, [value | events])
  end

  defp offset(stacktrace) do
    with [{_, _, _, opts} | _] <- stacktrace,
         %{cause: %{position: position}} <- opts[:error_info] do
      position
    else
      _ -> 0
    end
  end
end
