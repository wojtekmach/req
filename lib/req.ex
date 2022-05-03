defmodule Req do
  @external_resource "README.md"

  @moduledoc """
  The high-level API.

  Req is composed of three main pieces:

    * `Req` - the high-level API (you're here!)

    * `Req.Request` - the low-level API and the request struct

    * `Req.Steps` - the collection of built-in steps

  The high-level API is what most users of Req will use most of the time.

  ## Examples

  Making a GET request with `Req.get!/1`:

      iex> Req.get!("https://api.github.com/repos/elixir-lang/elixir").body["description"]
      "Elixir is a dynamic, functional language designed for building scalable and maintainable applications"

  Same, but by explicitly building request struct first:

      iex> req = Req.new(base_url: "https://api.github.com")
      iex> Req.get!(req, url: "/repos/elixir-lang/elixir").body["description"]
      "Elixir is a dynamic, functional language designed for building scalable and maintainable applications"

  Making a POST request with `Req.post!/2`:

      iex> Req.post!("https://httpbin.org/post", form: [comments: "hello!"]).body["form"]
      %{"comments" => "hello!"}
  """

  @type url() :: URI.t() | String.t()

  @doc """
  Returns a new request struct with built-in steps.

  See `request/1` for a list of available options. See `Req.Request` module documentation
  for more information on the underlying request struct.

  ## Examples

      iex> req = Req.new(url: "https://elixir-lang.org")
      iex> req.method
      :get
      iex> URI.to_string(req.url)
      "https://elixir-lang.org"

  """
  @spec new(options :: keyword()) :: Req.Request.t()
  def new(options \\ []) do
    options = Keyword.merge(default_options(), options)
    {adapter, options} = Keyword.pop(options, :adapter, &Req.Steps.run_finch/1)
    {method, options} = Keyword.pop(options, :method, :get)
    {headers, options} = Keyword.pop(options, :headers, [])
    {url, options} = Keyword.pop(options, :url, "")
    {body, options} = Keyword.pop(options, :body, "")
    options = Map.new(options)

    %Req.Request{
      adapter: adapter,
      method: method,
      url: url && URI.parse(url),
      headers: encode_headers(headers),
      body: body,
      options: options,
      request_steps: [
        &Req.Steps.put_default_user_agent/1,
        &Req.Steps.compressed/1,
        &Req.Steps.encode_body/1,
        &Req.Steps.put_base_url/1,
        &Req.Steps.auth/1,
        &Req.Steps.put_params/1,
        &Req.Steps.put_range/1,
        &Req.Steps.cache/1,
        &Req.Steps.put_plug/1
      ],
      response_steps: [
        &Req.Steps.retry/1,
        &Req.Steps.follow_redirects/1,
        &Req.Steps.decompress/1,
        &Req.Steps.output/1,
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

  With URL:

      iex> Req.get!("https://api.github.com/repos/elixir-lang/elixir").body["description"]
      "Elixir is a dynamic, functional language designed for building scalable and maintainable applications"

  With request struct:

      iex> req = Req.new(base_url: "https://api.github.com")
      iex> Req.get!(req, url: "/repos/elixir-lang/elixir").status
      200

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

  With URL:

      iex> Req.post!("https://httpbin.org/anything", body: "hello!").body["data"]
      "hello!"

      iex> Req.post!("https://httpbin.org/anything", form: [x: 1]).body["form"]
      %{"x" => "1"}

      iex> Req.post!("https://httpbin.org/anything", json: %{x: 2}).body["json"]
      %{"x" => 2}

  With request struct:

      iex> req = Req.new(url: "https://httpbin.org/anything")
      iex> Req.post!(req, body: "hello!").body["data"]
      "hello!"
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
      case options do
        {:form, data} ->
          IO.warn(
            "Req.post!(url, {:form, data}) is deprecated in favour of " <>
              "Req.post!(url, form: data)"
          )

          request!(method: :post, url: URI.parse(url), form: data)

        {:json, data} ->
          IO.warn(
            "Req.post!(url, {:json, data}) is deprecated in favour of " <>
              "Req.post!(url, json: data)"
          )

          request!(method: :post, url: URI.parse(url), json: data)

        data ->
          IO.warn("Req.post!(url, body) is deprecated in favour of Req.post!(url, body: body)")
          request!(method: :post, url: URI.parse(url), body: data)
      end
    end
  end

  @doc false
  def post!(url, body, options) do
    case body do
      {:form, data} ->
        IO.warn(
          "Req.post!(url, {:form, data}, options) is deprecated in favour of " <>
            "Req.post!(url, [form: data] ++ options)"
        )

        request!([method: :post, url: URI.parse(url), form: data] ++ options)

      {:json, data} ->
        IO.warn(
          "Req.post!(url, {:json, data}) is deprecated in favour of " <>
            "Req.post!(url, [json: data] ++ options)"
        )

        request!([method: :post, url: URI.parse(url), json: data] ++ options)

      data ->
        IO.warn(
          "Req.post!(url, body) is deprecated in favour of " <>
            "Req.post!(url, [body: body] ++ options)"
        )

        request!([method: :post, url: URI.parse(url), body: data] ++ options)
    end
  end

  @doc """
  Makes a PUT request.

  See `request/1` for a list of supported options.

  ## Examples

  With URL:

      iex> Req.put!("https://httpbin.org/anything", body: "hello!").body["data"]
      "hello!"

  With request struct:

      iex> req = Req.new(url: "https://httpbin.org/anything")
      iex> Req.put!(req, body: "hello!").body["data"]
      "hello!"
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
        "Req.put!(url, [#{type}: #{type}] ++ options)"
    )

    request!([method: :put, url: url, body: body] ++ options)
  end

  @doc """
  Makes a PATCH request.

  See `request/1` for a list of supported options.

  ## Examples

  With URL:

      iex> Req.patch!("https://httpbin.org/anything", body: "hello!").body["data"]
      "hello!"

  With request struct:

      iex> req = Req.new(url: "https://httpbin.org/anything")
      iex> Req.patch!(req, body: "hello!").body["data"]
      "hello!"
  """
  @spec patch!(url() | Req.Request.t(), options :: keyword()) :: Req.Response.t()
  def patch!(url_or_request, options \\ [])

  def patch!(%Req.Request{} = request, options) do
    request!(%{request | method: :patch}, options)
  end

  def patch!(url, options) do
    request!([method: :patch, url: url] ++ options)
  end

  @doc """
  Makes a DELETE request.

  See `request/1` for a list of supported options.

  ## Examples

  With URL:

      iex> Req.delete!("https://httpbin.org/anything").body["method"]
      "DELETE"

  With request struct:

      iex> req = Req.new(url: "https://httpbin.org/anything")
      iex> Req.delete!(req).body["method"]
      "DELETE"
  """
  @spec delete!(url() | Req.Request.t(), options :: keyword()) :: Req.Response.t()
  def delete!(url_or_request, options \\ [])

  def delete!(%Req.Request{} = request, options) do
    request!(%{request | method: :delete}, options)
  end

  def delete!(url, options) do
    request!([method: :delete, url: url] ++ options)
  end

  @doc """
  Makes an HTTP request.

  `request/1` and `request/2` functions give three ways of making requests:

    1. With a list of options, for example:

       ```
       Req.request(url: url)
       ```

    2. With a request struct, for example:

       ```
       Req.new(url: url) |> Req.request()
       ```

    3. With a request struct and more options, for example:

       ```
       Req.new(base_url: base_url) |> Req.request(url: url)
       ```

  This function as well as all the other ones in this module accept the same set of options described below.

  ## Options

  Basic request options:

    * `:method` - the request method, defaults to `:get`.

    * `:url` - the request URL.

    * `:headers` - the request headers.

      The headers are automatically encoded using these rules:

        * atom header names are turned into strings, replacing `-` with `_`. For example,
          `:user_agent` becomes `"user-agent"`

        * string header names are left as is

        * `NaiveDateTime` and `DateTime` header values are encoded as "HTTP date". Otherwise,
          the header value is encoded with `String.Chars.to_string/1`.

      If you set `:headers` options both in `Req.new/1` and `request/2`, the header lists are merged.

    * `:body` - the request body. The body is automatically encoded using the
      [`encode_body`](`Req.Steps.encode_body/1`) step.

  Additional URL options:

    * `:base_url` - if set, the request URL is prepended with this base URL (via
      [`put_base_url`](`Req.Steps.put_base_url/1`) step).

    * `:params` - if set, appends parameters to the request query string (via
      [`put_params`](`Req.Steps.put_params/1`) step).

  Authentication options:

    * `:auth` - sets request authentication (via [`auth`](`Req.Steps.auth/1`) step).

  Response body options:

    * `:raw` - if set to `true`, disables automatic body decompression
      ([`decompress`](`Req.Steps.decompress/1`) step) and decoding
      ([`decode_body`](`Req.Steps.decode_body/1`) step). Defaults to `false`.

    * `:output` - if set, writes the response body to a file (via
      [`output`](`Req.Steps.output/1`) step). Can be set to a string path or an atom
      `:remote_name` which would use the remote name as the filename in the current working
      directory. Once the file is written, the response body is replaced with `""`.

  Response redirect options ([`follow_redirects`](`Req.Steps.follow_redirects/1`) step):

    * `:follow_redirects` - if set to `false`, disables automatic response redirects. Defaults to `true`.

  Caching options ([`cache`](`Req.Steps.cache/1`) step):

    * `:cache` - if `true`, performs HTTP caching. Defaults to `false`.

    * `:cache_dir` - the directory to store the cache, defaults to `<user_cache_dir>/req`
      (see: `:filename.basedir/3`)

  Request adapters:

    * `:adapter` - adapter to use to make the actual HTTP request. See `:adapter` field description
      in the `Req.Request` module documentation for more information. Defaults to calling [`run_finch`](`Req.Steps.run_finch/1`).

    * `:plug` - if set, calls the given Plug instead of making an HTTP request over the network (via [`put_plug`](`Req.Steps.put_plug/1`) step).

  Finch options ([`run_finch`](`Req.Steps.run_finch/1`) step)

    * `:finch` - the `Finch` pool to use. Defaults to pool automatically started by `Req`.

    * `:finch_options` - options passed down to Finch when making the request, defaults to `[]`.
       See `Finch.request/3` for a list of available options.

  ## Examples

  With options keywords list:

      iex> {:ok, response} = Req.request(url: "https://api.github.com/repos/elixir-lang/elixir")
      iex> response.status
      200
      iex> response.body["description"]
      "Elixir is a dynamic, functional language designed for building scalable and maintainable applications"

  With request struct:

      iex> req = Req.new(url: "https://api.github.com/repos/elixir-lang/elixir")
      iex> {:ok, response} = Req.request(req)
      iex> response.status
      200

  With request struct and options:

      iex> req = Req.new(base_url: "https://api.github.com")
      iex> {:ok, response} = Req.request(req, url: "/repos/elixir-lang/elixir")
      iex> response.status
      200
  """
  @spec request(Req.Request.t() | keyword()) :: {:ok, Req.Response.t()} | {:error, Exception.t()}
  def request(request_or_options)

  def request(%Req.Request{} = request) do
    request(request, [])
  end

  def request(options) do
    request(Req.new(options), [])
  end

  @doc """
  Makes an HTTP request.

  See `request/1` for more information.
  """
  @spec request(Req.Request.t(), options :: keyword()) ::
          {:ok, Req.Response.t()} | {:error, Exception.t()}
  def request(request, options) do
    {request_options, options} = Keyword.split(options, [:method, :url, :headers, :body])

    request_options =
      if request_options[:headers] do
        update_in(request_options[:headers], &encode_headers/1)
      else
        request_options
      end

    request =
      Map.merge(request, Map.new(request_options), fn
        :url, _, url ->
          URI.parse(url)

        :headers, old, new ->
          old ++ new

        _, _, value ->
          value
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

  ## Examples

      iex> Req.request!(url: "https://api.github.com/repos/elixir-lang/elixir").status
      200
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

  ## Examples

      iex> req = Req.new(base_url: "https://api.github.com")
      iex> Req.request!(req, url: "/repos/elixir-lang/elixir").status
      200
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

  Sets default options for `Req.new/1`.

  Avoid setting default options in libraries as they are global.

  ## Examples

      iex> Req.default_options(base_url: "https://httpbin.org")
      iex> Req.get!("/statuses/201").status
      201
      iex> Req.new() |> Req.get!(url: "/statuses/201").status
      201
  """
  @spec default_options(keyword()) :: :ok
  def default_options(options) do
    Application.put_env(:req, :default_options, options)
  end

  defp encode_headers(headers) do
    for {name, value} <- headers do
      name =
        case name do
          atom when is_atom(atom) ->
            atom |> Atom.to_string() |> String.replace("_", "-")

          binary when is_binary(binary) ->
            binary
        end

      value =
        case value do
          %NaiveDateTime{} = naive_datetime ->
            Req.Steps.format_http_datetime(naive_datetime)

          %DateTime{} = datetime ->
            datetime |> DateTime.shift_zone!("Etc/UTC") |> Req.Steps.format_http_datetime()

          _ ->
            String.Chars.to_string(value)
        end

      {name, value}
    end
  end
end
