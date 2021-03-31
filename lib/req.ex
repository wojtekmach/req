defmodule Req do
  @external_resource "README.md"

  @moduledoc "README.md"
             |> File.read!()
             |> String.split("<!-- MDOC !-->")
             |> Enum.fetch!(1)

  @doc """
  Makes a GET request.
  """
  @doc api: :high_level
  def get!(url, opts \\ []) do
    case request(:get, url, opts) do
      {:ok, response} -> response
      {:error, error} -> raise error
    end
  end

  @doc """
  Makes an HTTP request.
  """
  @doc api: :high_level
  def request(method, url, opts \\ []) do
    method
    |> build(url, opts)
    |> add_default_steps()
    |> run()
  end

  ## Low-level API

  @doc """
  Builds a request pipeline.
  """
  @doc api: :low_level
  def build(method, url, opts \\ []) do
    body = Keyword.get(opts, :body, "")
    headers = Keyword.get(opts, :headers, [])

    %Req.Request{
      method: method,
      url: url,
      headers: headers,
      body: body
    }
  end

  @doc """
  Adds steps that should be reasonable defaults for most users.

    * request:

      * `default_headers/1`

    * response:

      * `decompress/2`
      * `decode/2`

  """
  @doc api: :low_level
  def add_default_steps(request) do
    request
    |> add_request_steps([
      &default_headers/1
    ])
    |> add_response_steps([
      &decompress/2,
      &decode/2
    ])
  end

  @doc """
  Adds request steps.
  """
  @doc api: :low_level
  def add_request_steps(request, steps) do
    update_in(request.request_steps, &(&1 ++ steps))
  end

  @doc """
  Adds response steps.
  """
  @doc api: :low_level
  def add_response_steps(request, steps) do
    update_in(request.response_steps, &(&1 ++ steps))
  end

  @doc """
  Adds error steps.
  """
  @doc api: :low_level
  def add_error_steps(request, steps) do
    update_in(request.error_steps, &(&1 ++ steps))
  end

  @doc """
  Runs a request pipeline.

  Returns `{:ok, response}` or `{:error, exception}`.
  """
  @doc api: :low_level
  def run(request) do
    result =
      Enum.reduce_while(request.request_steps, request, fn step, acc ->
        case step.(acc) do
          %Req.Request{} = request ->
            {:cont, request}

          {%Req.Request{halted: true}, _response_or_exception} = halt ->
            {:halt, {:halt, halt}}

          {request, %Finch.Response{} = response} ->
            {:halt, {:response, request, response}}

          {request, %{__exception__: true} = exception} ->
            {:halt, {:error, request, exception}}
        end
      end)

    case result do
      %Req.Request{} = request ->
        finch_request = Finch.build(request.method, request.url, request.headers, request.body)

        case Finch.request(finch_request, Req.Finch) do
          {:ok, response} ->
            run_response(request, response)

          {:error, exception} ->
            run_error(request, exception)
        end

      {:response, request, response} ->
        run_response(request, response)

      {:error, request, exception} ->
        run_error(request, exception)

      {:halt, {_request, response_or_exception}} ->
        result(response_or_exception)
    end
  end

  @doc """
  Runs a request pipeline and returns a response or raises an error.

  See `run/1`.
  """
  @doc api: :low_level
  def run!(request) do
    case run(request) do
      {:ok, response} -> response
      {:error, exception} -> raise exception
    end
  end

  defp run_response(request, response) do
    {_request, response_or_exception} =
      Enum.reduce_while(request.response_steps, {request, response}, fn step,
                                                                        {request, response} ->
        case step.(request, response) do
          {%Req.Request{halted: true} = request, response_or_exception} ->
            {:halt, {request, response_or_exception}}

          {request, %Finch.Response{} = response} ->
            {:cont, {request, response}}

          {request, %{__exception__: true} = exception} ->
            {:halt, run_error(request, exception)}
        end
      end)

    result(response_or_exception)
  end

  defp run_error(request, exception) do
    {_request, response_or_exception} =
      Enum.reduce_while(request.error_steps, {request, exception}, fn step,
                                                                      {request, exception} ->
        case step.(request, exception) do
          {%Req.Request{halted: true} = request, response_or_exception} ->
            {:halt, {request, response_or_exception}}

          {request, %{__exception__: true} = exception} ->
            {:cont, {request, exception}}

          {request, %Finch.Response{} = response} ->
            {:halt, run_response(request, response)}
        end
      end)

    result(response_or_exception)
  end

  defp result(%Finch.Response{} = response) do
    {:ok, response}
  end

  defp result(%{__exception__: true} = exception) do
    {:error, exception}
  end

  ## Request steps

  @user_agent "req/#{Mix.Project.config()[:version]}"

  @doc """
  Adds common request headers.

  Currently the following headers are added:

    * `"user-agent"` - `#{inspect(@user_agent)}`

  """
  @doc api: :request
  def default_headers(request) do
    put_new_header(request, "user-agent", @user_agent)
  end

  ## Response steps

  @doc """
  Decompresses the response body based on the `content-encoding` header.
  """
  @doc api: :response
  def decompress(request, response) do
    compression_algorithms = get_content_encoding_header(response.headers)
    {request, update_in(response.body, &decompress_body(&1, compression_algorithms))}
  end

  defp decompress_body(body, algorithms) do
    Enum.reduce(algorithms, body, &decompress_with_algorithm(&1, &2))
  end

  defp decompress_with_algorithm(gzip, body) when gzip in ["gzip", "x-gzip"] do
    :zlib.gunzip(body)
  end

  defp decompress_with_algorithm("deflate", body) do
    :zlib.unzip(body)
  end

  defp decompress_with_algorithm("identity", body) do
    body
  end

  defp decompress_with_algorithm(algorithm, _body) do
    raise("unsupported decompression algorithm: #{inspect(algorithm)}")
  end

  @doc """
  Decodes the response body based on the `content-type` header.
  """
  @doc api: :response
  def decode(request, response) do
    case List.keyfind(response.headers, "content-type", 0) do
      {_, "application/json" <> _} ->
        {request, update_in(response.body, &Jason.decode!/1)}

      {_, "application/gzip" <> _} ->
        {request, update_in(response.body, &:zlib.gunzip/1)}

      {_, "application/x-gzip" <> _} ->
        {request, update_in(response.body, &:zlib.gunzip/1)}

      _ ->
        {request, response}
    end
  end

  ## Error steps

  @doc """
  Retries a request in face of errors.

  This function can be used as either or both response and error step. It retries a request that
  resulted in:

    * a response with status 5xx

    * an exception

  """
  @doc api: :error
  def retry(request, response_or_exception)

  def retry(request, %{status: status} = response) when status < 500 do
    {request, response}
  end

  def retry(request, response_or_exception) do
    max_attempts = 2
    attempt = Req.Request.get_private(request, :retry_attempt, 0)

    if attempt < max_attempts do
      request = Req.Request.put_private(request, :retry_attempt, attempt + 1)
      {_, result} = run(%{request | request_steps: []})
      {Req.Request.halt(request), result}
    else
      {request, response_or_exception}
    end
  end

  ## Utilities

  defp put_new_header(struct, name, value) do
    if Enum.any?(struct.headers, fn {key, _} -> String.downcase(key) == name end) do
      struct
    else
      update_in(struct.headers, &[{name, value} | &1])
    end
  end

  defp get_content_encoding_header(headers) do
    if value = get_header(headers, "content-encoding") do
      value
      |> String.downcase()
      |> String.split(",", trim: true)
      |> Stream.map(&String.trim/1)
      |> Enum.reverse()
    else
      []
    end
  end

  defp get_header(headers, name) do
    Enum.find_value(headers, nil, fn {key, value} ->
      if String.downcase(key) == name do
        value
      else
        nil
      end
    end)
  end
end
