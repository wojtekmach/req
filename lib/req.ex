defmodule Req do
  @external_resource "README.md"

  @moduledoc "README.md"
             |> File.read!()
             |> String.split("<!-- MDOC !-->")
             |> Enum.fetch!(1)

  @type url() :: URI.t() | String.t()

  @type method() :: :get | :post | :put | :delete

  @default_options %{
    # request steps
    auth: nil,
    base_url: nil,
    cache: nil,
    cache_dir: nil,
    params: [],
    range: nil,
    finch: Req.Finch,
    pool_timeout: 5000,
    receive_timeout: 15000,

    # response steps
    follow_redirects: true,
    location_trusted: false,
    raw: false,

    # error steps
    max_retries: 2,
    retry: true,
    retry_delay: 2000
  }

  @doc """
  Returns a new request struct with default steps.

  See `request/1` for a list of available options.
  """
  @spec new(options :: keyword()) :: Req.Request.t()
  def new(options \\ []) do
    {adapter, options} = Keyword.pop(options, :adapter, &Req.Steps.run_finch/1)
    {method, options} = Keyword.pop(options, :method, :get)
    {url, options} = Keyword.pop(options, :url, nil)
    {headers, options} = Keyword.pop(options, :headers, [])
    {body, options} = Keyword.pop(options, :body, "")
    options = Map.merge(@default_options, Map.new(options))

    %Req.Request{
      adapter: adapter,
      method: method,
      url: url && URI.parse(url),
      headers: headers,
      body: body,
      options: options,
      request_steps: [
        &Req.Steps.encode_headers/1,
        &Req.Steps.put_default_headers/1,
        &Req.Steps.encode_body/1,
        &Req.Steps.put_base_url/1,
        &Req.Steps.auth/1,
        &Req.Steps.put_params/1,
        &Req.Steps.put_range/1,
        &Req.Steps.put_if_modified_since/1
      ],
      response_steps: [
        &Req.Steps.retry/1,
        &Req.Steps.follow_redirects/1,
        &Req.Steps.decompress/1,
        &Req.Steps.decode_body/1
      ],
      error_steps: [
        &Req.Steps.retry/1
      ]
    }
  end

  @doc """
  Makes a GET request.

  See `request/1` for a list of supported options.

  ## Examples

      iex> Req.get!("https://api.github.com/repos/elixir-lang/elixir").body["description"]
      "Elixir is a dynamic, functional language designed for building scalable and maintainable applications"

  """
  @spec get!(url() | Req.Request.t(), options :: keyword()) :: Req.Response.t()
  def get!(url_or_request, options \\ [])

  def get!(%Req.Request{} = request, options) do
    request!(%{request | method: :get}, options)
  end

  def get!(url, options) do
    request!([method: :get, url: URI.parse(url)] ++ options)
  end

  @doc """
  Makes a POST request.

  See `request/1` for a list of supported options.

  ## Examples

      iex> Req.post!("https://httpbin.org/post", body: {:form, foo: "hello!"}).body["form"]
      #=> %{"comments" => "hello!"}

  """
  @spec post!(url() | Req.Request.t(), options :: keyword()) :: Req.Response.t()
  def post!(url_or_request, options \\ [])

  def post!(%Req.Request{} = request, options) do
    request!(%{request | method: :post}, options)
  end

  def post!(url, options) do
    if Keyword.keyword?(options) do
      request!([method: :post, url: URI.parse(url)] ++ options)
    else
      IO.warn("Req.post!(url, body) is deprecated in favour of Req.post!(url, body: body)")
      request!(method: :post, url: URI.parse(url), body: options)
    end
  end

  @doc false
  def post!(url, body, options) do
    IO.warn(
      "Req.post!(url, body, options) is deprecated in favour of " <>
        "Req.post!(url, [body: body] ++ options)"
    )

    request!([method: :post, url: URI.parse(url), body: body] ++ options)
  end

  @doc """
  Makes a PUT request.

  See `request/1` for a list of supported options.

  ## Examples

      iex> Req.put!("https://httpbin.org/anything", body: "the body").body |> Map.take(["data", "method"])
      %{"data" => "the body", "method" => "PUT"}

  """
  @spec put!(url() | Req.Request.t(), options :: keyword()) :: Req.Response.t()
  def put!(url_or_request, options \\ [])

  def put!(%Req.Request{} = request, options) do
    request!(%{request | method: :put}, options)
  end

  def put!(url, options) do
    if Keyword.keyword?(options) do
      request!([method: :put, url: URI.parse(url)] ++ options)
    else
      IO.warn("Req.put!(url, body) is deprecated in favour of Req.put!(url, body: body)")
      request!(url: URI.parse(url), body: options)
    end
  end

  @doc false
  def put!(%URI{} = url, {type, _} = body, options) when type in [:form, :json] do
    IO.warn(
      "Req.put!(url, {:#{type}, #{type}}, options) is deprecated in favour of " <>
        "Req.put!(url, [body: {:#{type}, #{type}}] ++ options)"
    )

    request!([method: :put, url: url, body: body] ++ options)
  end

  @doc """
  Makes a DELETE request.

  See `request/1` for a list of supported options.
  """
  @spec delete!(url(), options :: keyword()) :: Req.Response.t()
  def delete!(url, options \\ []) do
    request!([method: :delete, url: url] ++ options)
  end

  @doc """
  Makes an HTTP request.

  ## Options

    * `:method` - the request method, defaults to `:get`.

    * `:url` - the request URL.

    * `:headers` - the request headers. The headers are automatically encoded using the `Req.Steps.encode_headers/1` step.

    * `:body` - the request body. The body is automatically encoded using the `Req.Steps.encode_body/1` step.

    * `:base_url` - if set, the URL is prepended with this base URL. Defaults to `nil`.
      See `Req.Steps.put_base_url/1` for more information.

    * `:params` - appends parameters to the request query string. Defaults to `[]`.
      See `Req.Steps.put_params/1` for more information.

    * `:raw` - if set to `true`, disables automatic body decompression (`Req.Steps.decompress/1`) and
      and decoding (`Req.Steps.decode_body/1`). Defaults to `false`.

    * `:adapter` - adapter to use to make the actual HTTP request. See `:adapter` field description
      in the `Req.Request` module documentation for more information. Defaults to calling `Req.Steps.run_finch/1`.

  `put_if_modified_since/1` options:

    * `:cache` - if `true`, performs caching. Defaults to `false`.

    * `:dir` - the directory to store the cache, defaults to `<user_cache_dir>/req`
      (see: `:filename.basedir/3`)

  `follow_redirects/1` options:

    * `:follow_redirects` - if set to `false`, disables automatic response redirects. Defaults to `true`.

    * `:max_redirects` - the maximum number of redirects. Defaults to `3`.

  `run_finch/1` options:

    * `:finch` - the `Finch` pool to use. Defaults to `Req.Finch` which is automatically started by `Req`.

    * `:finch_options` - options passed down to Finch when making the request, defaults to `[]`.
       See `Finch.request/3` for a list of available options.

  ## Examples

      iex> {:ok, response} = Req.request(url: "https://api.github.com/repos/elixir-lang/elixir")
      iex> response.body
      "Elixir is a dynamic, functional language designed for building scalable and maintainable applications"

      iex> req = Req.new(url: "https://api.github.com/repos/elixir-lang/elixir")
      iex> {:ok, %Req.Response{}} = Req.request(req)

      iex> req = Req.new(base_url: "https://api.github.com")
      iex> {:ok, %Req.Response{}} = Req.request(req, url: "/repos/elixir-lang/elixir")
  """
  @spec request(Req.Request.t() | keyword()) ::
          {:ok, Req.Response.t()} | {:error, Exception.t()}
  def request(request_or_options)

  def request(%Req.Request{} = request) do
    request(request, [])
  end

  def request(options) do
    request(Req.new(options), [])
  end

  @doc """
  Makes an HTTP request.
  """
  @spec request(Req.Request.t(), options :: keyword()) ::
          {:ok, Req.Response.t()} | {:error, Exception.t()}
  def request(request, options) do
    options = Keyword.merge(default_options(), options)

    {request, options} =
      Enum.reduce([:method, :url, :headers, :body], {request, options}, fn option,
                                                                           {request, options} ->
        case Keyword.fetch(options, option) do
          {:ok, value} ->
            value =
              if option == :url do
                URI.parse(value)
              else
                value
              end

            # TODO: merge headers

            {%{request | option => value}, Keyword.delete(options, option)}

          :error ->
            {request, options}
        end
      end)

    request = update_in(request.options, &Map.merge(&1, Map.new(options)))
    Req.Request.run(request)
  end

  @doc false
  def request(method, url, options) do
    IO.warn(
      "Req.request(method, url, options) is deprecated in favour of " <>
        "Req.request!([method: method, url: url] ++ options)"
    )

    request([method: method, url: URI.parse(url)] ++ options)
  end

  @doc """
  Makes an HTTP request and returns a response or raises an error.

  See `request/1` for more information.
  """
  @spec request!(Req.Request.t() | keyword()) :: Req.Response.t()
  def request!(request_or_options) do
    case request(request_or_options) do
      {:ok, response} -> response
      {:error, exception} -> raise exception
    end
  end

  @doc """
  Makes an HTTP request and returns a response or raises an error.

  See `request/1` for more information.
  """
  @spec request!(Req.Request.t(), options :: keyword()) :: Req.Response.t()
  def request!(request, options) do
    case request(request, options) do
      {:ok, response} -> response
      {:error, exception} -> raise exception
    end
  end

  @doc """
  Returns default options.

  See `default_options/1` for more information.
  """
  @spec default_options() :: keyword()
  def default_options() do
    Application.get_env(:req, :default_options, [])
  end

  @doc """
  Sets default options.

  The default options are used by `request/1`, `get!/2`, and similar functions.

  Avoid setting default options in libraries as they are global.
  """
  @spec default_options(keyword()) :: :ok
  def default_options(options) do
    Application.put_env(:req, :default_options, options)
  end
end
