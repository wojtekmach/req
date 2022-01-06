defmodule Req do
  @external_resource "README.md"

  @moduledoc "README.md"
             |> File.read!()
             |> String.split("<!-- MDOC !-->")
             |> Enum.fetch!(1)

  @type url() :: URI.t() | String.t()

  @type method() :: :get | :post | :put | :delete

  @doc """
  Makes a GET request.

  See `request/3` for a list of supported options.
  """
  @spec get!(url(), keyword()) :: Req.Response.t()
  def get!(url, options \\ []) do
    request!(:get, url, options)
  end

  @doc """
  Makes a POST request.

  See `request/3` for a list of supported options.
  """
  @spec post!(url(), body :: term(), keyword()) :: Req.Response.t()
  def post!(url, body, options \\ []) do
    options = Keyword.put(options, :body, body)
    request!(:post, url, options)
  end

  @doc """
  Makes a PUT request.

  See `request/3` for a list of supported options.
  """
  @spec put!(url(), body :: term(), keyword()) :: Req.Response.t()
  def put!(url, body, options \\ []) do
    options = Keyword.put(options, :body, body)
    request!(:put, url, options)
  end

  @doc """
  Makes a DELETE request.

  See `request/3` for a list of supported options.
  """
  @spec delete!(url(), keyword()) :: Req.Response.t()
  def delete!(url, options \\ []) do
    request!(:delete, url, options)
  end

  @doc """
  Makes an HTTP request.

  ## Options

    * `:headers` - request headers, defaults to `[]`

    * `:body` - request body, defaults to `""`

    * `:finch` - Finch pool to use, defaults to `Req.Finch` which is automatically started
      by the application. See `Finch` module documentation for more information on starting pools.

    * `:finch_options` - Options passed down to Finch when making the request, defaults to `[]`.
      See `Finch.request/3` for more information.

  The `options` are passed down to `Req.Steps.put_default_steps/2`, see its documentation for more
  information how they are being used.

  The `options` are merged with default options set with `default_options/1`.
  """
  @spec request(method(), url(), keyword()) ::
          {:ok, Req.Response.t()} | {:error, Exception.t()}
  def request(method, url, options \\ []) do
    options = Keyword.merge(default_options(), options)

    method
    |> Req.Request.build(url, options)
    |> Req.Steps.put_default_steps(options)
    |> Req.Request.run()
  end

  @doc """
  Makes an HTTP request and returns a response or raises an error.

  See `request/3` for more information.
  """
  @spec request!(method(), url(), keyword()) :: Req.Response.t()
  def request!(method, url, options \\ []) do
    options = Keyword.merge(default_options(), options)

    method
    |> Req.Request.build(url, options)
    |> Req.Steps.put_default_steps(options)
    |> Req.Request.run!()
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

  The default options are used by `get!/2`, `post!/3`, `put!/3`,
  `delete!/2`, `request/3`, and `request!/3` functions.

  Avoid setting default options in libraries as they are global.
  """
  @spec default_options(keyword()) :: :ok
  def default_options(options) do
    Application.put_env(:req, :default_options, options)
  end
end
