defmodule Req.Response do
  @moduledoc """
  The response struct.

  Fields:

    * `:status` - the HTTP status code.

    * `:headers` - the HTTP response headers. The header names should be downcased.
      See also "Headers" section in `Req` module documentation.

    * `:body` - the HTTP response body.

    * `:trailers` - the HTTP response trailers. The trailer names must be downcased.

    * `:private` - a map reserved for libraries and frameworks to use.
      Prefix the keys with the name of your project to avoid any future
      conflicts. Only accepts `t:atom/0` keys.
  """

  @type t() :: %__MODULE__{
          status: non_neg_integer(),
          headers: %{optional(binary()) => [binary()]},
          body: binary() | %Req.Response.Async{} | term(),
          trailers: %{optional(binary()) => [binary()]},
          private: map()
        }

  defstruct status: 200,
            headers: Req.Fields.new([]),
            body: "",
            trailers: Req.Fields.new([]),
            private: %{}

  @doc """
  Returns a new response.

  Expects a keyword list, map, or struct containing the response keys.

  ## Example

      iex> Req.Response.new(status: 200, body: "body")
      %Req.Response{status: 200, headers: %{}, body: "body"}

      iex> finch_response = %Finch.Response{status: 200, headers: [{"content-type", "text/html"}]}
      iex> Req.Response.new(finch_response)
      %Req.Response{status: 200, headers: %{"content-type" => ["text/html"]}, body: ""}

  """
  @spec new(options :: keyword() | map() | struct()) :: t()
  def new(options \\ [])

  def new(%{} = options) do
    options =
      Map.take(options, [:status, :headers, :body, :trailers])
      |> Map.update(
        :headers,
        Req.Fields.new([]),
        &Req.Fields.new_without_normalize_with_duplicates/1
      )
      |> Map.update(
        :trailers,
        Req.Fields.new([]),
        &Req.Fields.new_without_normalize_with_duplicates/1
      )

    struct!(__MODULE__, options)
  end

  def new(options) when is_list(options) do
    new(Map.new(options))
  end

  @doc """
  Converts response to a map for interoperability with other libraries.

  The resulting map has the folowing fields:

    * `:status`
    * `:headers`
    * `:trailers`
    * `:body`

  Note, `body` can be any term since Req built-in and custom steps usually transform it.

  ## Examples

      iex> resp = Req.Response.new(status: 200, headers: %{"server" => ["test"]}, body: "hello")
      iex> Req.Response.to_map(resp)
      %{status: 200, body: "hello", headers: [{"server", "test"}], trailers: []}
  """
  @spec to_map(t()) :: %{
          status: non_neg_integer(),
          headers: [{binary(), binary()}],
          trailers: [{binary(), binary()}],
          body: term()
        }
  def to_map(%Req.Response{} = resp) do
    %{
      status: resp.status,
      headers: Req.Fields.get_list(resp.headers),
      trailers: Req.Fields.get_list(resp.trailers),
      body: resp.body
    }
  end

  @doc """
  Builds or updates a response with JSON body.

  ## Example

      iex> Req.Response.json(%{hello: 42})
      %Req.Response{
        status: 200,
        headers: %{"content-type" => ["application/json"]},
        body: ~s|{"hello":42}|
      }

      iex> resp = Req.Response.new()
      iex> Req.Response.json(resp, %{hello: 42})
      %Req.Response{
        status: 200,
        headers: %{"content-type" => ["application/json"]},
        body: ~s|{"hello":42}|
      }

  If the request already contains a 'content-type' header, it is kept as is:

      iex> Req.Response.new()
      iex> |> Req.Response.put_header("content-type", "application/vnd.api+json; charset=utf-8")
      iex> |> Req.Response.json(%{hello: 42})
      %Req.Response{
        status: 200,
        headers: %{"content-type" => ["application/vnd.api+json; charset=utf-8"]},
        body: ~s|{"hello":42}|
      }
  """
  @spec json(t(), body :: term()) :: t()
  def json(response \\ new(), body) do
    response =
      update_in(response.headers, &Req.Fields.put_new(&1, "content-type", "application/json"))

    Map.replace!(response, :body, Jason.encode!(body))
  end

  @doc """
  Gets the value for a specific private `key`.
  """
  @spec get_private(t(), key :: atom(), default :: term()) :: term()
  def get_private(%Req.Response{} = response, key, default \\ nil) when is_atom(key) do
    Map.get(response.private, key, default)
  end

  @doc """
  Assigns a private `key` to `value`.
  """
  @spec put_private(t(), key :: atom(), value :: term()) :: t()
  def put_private(%Req.Response{} = response, key, value) when is_atom(key) do
    put_in(response.private[key], value)
  end

  @doc """
  Updates private `key` with the given function.

  If `key` is present in request private map then the existing value is passed to `fun` and its
  result is used as the updated value of `key`. If `key` is not present, `default` is inserted
  as the value of `key`. The default value will not be passed through the update function.

  ## Examples

      iex> resp = %Req.Response{private: %{a: 1}}
      iex> Req.Response.update_private(resp, :a, 11, & &1 + 1).private
      %{a: 2}
      iex> Req.Response.update_private(resp, :b, 11, & &1 + 1).private
      %{a: 1, b: 11}
  """
  @spec update_private(t(), key :: atom(), default :: term(), (atom() -> term())) :: t()
  def update_private(%Req.Response{} = response, key, initial, fun)
      when is_atom(key) and is_function(fun, 1) do
    update_in(response.private, &Map.update(&1, key, initial, fun))
  end

  @doc """
  Returns the values of the header specified by `name`.

  See also "Headers" section in `Req` module documentation.

  ## Examples

      iex> Req.Response.get_header(response, "content-type")
      ["application/json"]
  """
  @spec get_header(t(), binary()) :: [binary()]
  def get_header(%Req.Response{} = resp, name) when is_binary(name) do
    Req.Fields.get_values(resp.headers, name)
  end

  @doc """
  Adds a new response header `name` if not present, otherwise replaces the
  previous value of that header with `value`.

  See also "Headers" section in `Req` module documentation.

  ## Examples

      iex> resp = Req.Response.put_header(%Req.Response{}, "content-type", "application/json")
      iex> resp.headers
      %{"content-type" => ["application/json"]}
  """
  @spec put_header(t(), binary(), binary()) :: t()
  def put_header(%Req.Response{} = resp, name, value) when is_binary(name) and is_binary(value) do
    update_in(resp.headers, &Req.Fields.put(&1, name, value))
  end

  @doc """
  Deletes the header given by `name`.

  All occurrences of the header are deleted, in case the header is repeated multiple times.

  See also "Headers" section in `Req` module documentation.

  ## Examples

      iex> Req.Response.get_header(resp, "cache-control")
      ["max-age=600", "no-transform"]
      iex> resp = Req.Response.delete_header(resp, "cache-control")
      iex> Req.Response.get_header(resp, "cache-control")
      []

  """
  def delete_header(%Req.Response{} = resp, name) when is_binary(name) do
    update_in(resp.headers, &Req.Fields.delete(&1, name))
  end

  @doc """
  Returns the `retry-after` header delay value in seconds.

  Returns `nil` if the header is not found or the computed number of seconds is negative.
  """
  @spec get_retry_after(t()) :: integer() | nil
  def get_retry_after(response) do
    case get_header(response, "retry-after") do
      [delay] ->
        retry_delay_in_ms(delay)

      [] ->
        nil
    end
  end

  defp retry_delay_in_ms(delay_value) do
    case Integer.parse(delay_value) do
      {seconds, ""} ->
        if seconds >= 0 do
          :timer.seconds(seconds)
        end

      :error ->
        milliseconds =
          delay_value
          |> Req.Utils.parse_http_date!()
          |> DateTime.diff(DateTime.utc_now(), :millisecond)

        if milliseconds >= 0 do
          milliseconds
        end
    end
  end
end
