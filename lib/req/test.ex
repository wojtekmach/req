defmodule Req.Test do
  @moduledoc """
  Conveniences for testing requests and responses.

  This module is useful mostly for testing steps and plugins. It provides
  functions to preview a request after all of its steps have been executed.
  You can also test the result of the response and error pipelines by
  overriding the response or exception returned by the test adapter.
  """
  alias Req.{Request, Response}

  @doc """
  Performs a test run on the request.

  Refer to `run/2` for more information.

  ## Examples

      iex> {:ok, res} = Req.new(base_url: "http://httpbin.org") |> Req.Test.run()
      iex> res.body.url
      URI.parse("http://httpbin.org")

      iex> {:ok, res} = Req.new(base_url: "http://httpbin.org", url: "/get") |> Req.Test.run()
      iex> res.body.url
      URI.parse("http://httpbin.org/get")

      iex> {:ok, res} = Req.new(base_url: "http://httpbin.org", url: "/get", params: %{a: :b}) |> Req.Test.run()
      iex> res.body.url
      URI.parse("http://httpbin.org/get?a=b")
  """
  @spec run(Request.t()) :: {:ok, Response.t()} | {:error, Exception.t()}
  def run(%Request{} = req) do
    run(req, [])
  end

  @doc """
  Performs a test run on the request with options.

  This is mostly useful for testing expectations after all request steps have
  been applied. The request pipeline is executed with a custom adapter that
  returns the modified request struct.

  ## Options

    - `:response` - A response, either `Req.Response.t()` or `Exception.t()`
      to be returned as the response. The value will be sent through the
      response pipeline or the error pipeline, for responses and exceptions
      respectively. Defaults to a Response containing the Request struct
      after the request steps have executed. The default value is `nil`.

  ## Examples

      iex> {:ok, res} = Req.new(base_url: "http://httpbin.org") |> Req.Test.run(url: "/get")
      iex> res.body.url
      URI.parse("http://httpbin.org/get")

      iex> {:ok, res} = Req.new(base_url: "http://httpbin.org", url: "/get") |> Req.Test.run(params: %{a: :b})
      iex> res.body.url
      URI.parse("http://httpbin.org/get?a=b")

      iex> {:ok, res} = Req.new(url: "http://httpbin.org") |> Req.Test.run(response: Req.Response.new(body: "hi!"))
      iex> res.body
      "hi!"

      iex> Req.new(url: "http://httpbin.org") |> Req.Test.run(response: %RuntimeError{message: "boom"})
      {:error, %RuntimeError{message: "boom"}}

      iex> Req.new(url: "http://httpbin.org") |> Req.Test.run(response: :foo)
      {:error, %ArgumentError{message: "invalid response given to Req.Test.run/2, expected Req.Response.t() or Exception.t(), got: :foo"}}
  """
  @spec run(Request.t(), Keyword.t()) :: {:ok, Response.t()} | {:error, Exception.t()}
  def run(%Request{} = req, options) when is_list(options) do
    req
    |> Request.append_request_steps(test_run: &__MODULE__.test/1)
    |> Request.register_options([:response])
    |> Req.request(options)
  end

  @doc """
  Performs a test run on the request and returns the response or raises an error.

  Refer to `run/2` for more information.

  ## Examples

      iex> res = Req.new(url: "http://httpbin.org") |> Req.Test.run!()
      iex> res.body.url
      URI.parse("http://httpbin.org")

      iex> res = Req.new(base_url: "http://httpbin.org", url: "/get") |> Req.Test.run!()
      iex> res.body.url
      URI.parse("http://httpbin.org/get")

      iex> res = Req.new(base_url: "http://httpbin.org", url: "/get", params: %{a: :b}) |> Req.Test.run!()
      iex> res.body.url
      URI.parse("http://httpbin.org/get?a=b")
  """
  @spec run!(Request.t()) :: Response.t()
  def run!(%Request{} = req) do
    case run(req) do
      {:ok, req} -> req
      {:error, %{__exception__: true} = error} -> raise error
    end
  end

  @doc """
  Performs a test run on the request and returns the response or raises an error.

  Refer to `run/2` for more information.

      iex> res = Req.new(base_url: "http://httpbin.org") |> Req.Test.run!(url: "/get")
      iex> res.body.url
      URI.parse("http://httpbin.org/get")

      iex> res = Req.new(base_url: "http://httpbin.org", url: "/get") |> Req.Test.run!(params: %{a: :b})
      iex> res.body.url
      URI.parse("http://httpbin.org/get?a=b")

      iex> res = Req.new(url: "http://httpbin.org") |> Req.Test.run!(response: Req.Response.new(body: "hi!"))
      iex> res.body
      "hi!"

      iex> Req.new(url: "http://httpbin.org") |> Req.Test.run!(response: %RuntimeError{message: "boom"})
      ** (RuntimeError) boom

      iex> Req.new(url: "http://httpbin.org") |> Req.Test.run!(response: :foo)
      ** (ArgumentError) invalid response given to Req.Test.run/2, expected Req.Response.t() or Exception.t(), got: :foo
  """
  @spec run!(Request.t(), Keyword.t()) :: Response.t()
  def run!(%Request{} = req, options) when is_list(options) do
    case run(req, options) do
      {:ok, req} -> req
      {:error, %{__exception__: true} = error} -> raise error
    end
  end

  @doc """
  Runs the request using the test adapter.

  The request is not actually made. Instead, this step halts the given request
  and by default returns the request in the response body. You can use the
  `:response` option to either `run/2` or `run!/2` to test run a specific
  response or exception.

  Refer to `run/2` for more information.
  """
  def test(%Request{} = req) do
    req = req |> Request.halt()

    case Map.fetch(req.options, :response) do
      {:ok, response_or_exception} -> response(req, response_or_exception)
      :error -> response(req, Response.new(body: req))
    end
  end

  defp response(%Request{} = req, %Response{} = res) do
    {req, res}
  end

  defp response(%Request{} = req, %{__exception__: true} = exception) do
    {req, exception}
  end

  defp response(%Request{} = req, other) do
    msg =
      "invalid response given to #{inspect(__MODULE__)}.run/2, " <>
        "expected Req.Response.t() or Exception.t(), got: #{inspect(other)}"

    {req, %ArgumentError{message: msg}}
  end
end
