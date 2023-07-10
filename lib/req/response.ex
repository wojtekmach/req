defmodule Req.Response do
  @moduledoc """
  The response struct.

  Fields:

    * `:status` - the HTTP status code

    * `:headers` - the HTTP response headers

    * `:body` - the HTTP response body

    * `:private` - a map reserved for libraries and frameworks to use.
      Prefix the keys with the name of your project to avoid any future
      conflicts. Only accepts `t:atom/0` keys.
  """

  @type t() :: %__MODULE__{
          status: non_neg_integer(),
          headers: [{binary(), binary()}],
          body: binary() | term(),
          private: map()
        }

  defstruct status: 200,
            headers: [],
            body: "",
            private: %{}

  @doc false
  def fetch(response, key) when is_binary(key) do
    case get_header(response, key) do
      [value] -> {:ok, value}
      [] -> :error
      _ -> raise "multiple values for header #{key}, use Req.Response.get_header/2 instead"
    end
  end

  @doc """
  Returns a new response.

  Expects a keyword list, map, or struct containing the response keys.

  ## Example

      iex> Req.Response.new(status: 200, body: "body")
      %Req.Response{status: 200, headers: [], body: "body"}

      iex> finch_response = %Finch.Response{status: 200}
      iex> Req.Response.new(finch_response)
      %Req.Response{status: 200, headers: [], body: ""}

  """
  @spec new(options :: keyword() | map() | struct()) :: t()
  def new(options \\ [])

  def new(options) when is_list(options), do: new(Map.new(options))

  def new(options) do
    options = Map.take(options, [:status, :headers, :body])
    struct!(__MODULE__, options)
  end

  @doc """
  Builds or updates a response with JSON body.

  ## Example

      iex> Req.Response.json(%{hello: 42})
      %Req.Response{
        status: 200,
        headers: [{"content-type", "application/json"}],
        body: ~s|{"hello":42}|
      }

      iex> resp = Req.Response.new()
      iex> Req.Response.json(resp, %{hello: 42})
      %Req.Response{
        status: 200,
        headers: [{"content-type", "application/json"}],
        body: ~s|{"hello":42}|
      }

  If the request already contains a 'content-type' header, it is kept as is:

      iex> Req.Response.new()
      iex> |> Req.Response.put_header("content-type", "application/vnd.api+json; charset=utf-8")
      iex> |> Req.Response.json(%{hello: 42})
      %Req.Response{
        status: 200,
        headers: [{"content-type", "application/vnd.api+json; charset=utf-8"}],
        body: ~s|{"hello":42}|
      }
  """
  @spec json(t(), body :: term()) :: t()
  def json(response \\ new(), body) do
    response =
      case get_header(response, "content-type") do
        [] ->
          put_header(response, "content-type", "application/json")

        _ ->
          response
      end

    Map.replace!(response, :body, Jason.encode!(body))
  end

  @doc """
  Gets the value for a specific private `key`.
  """
  @spec get_private(t(), key :: atom(), default :: term()) :: term()
  def get_private(response, key, default \\ nil) when is_atom(key) do
    Map.get(response.private, key, default)
  end

  @doc """
  Assigns a private `key` to `value`.
  """
  @spec put_private(t(), key :: atom(), value :: term()) :: t()
  def put_private(response, key, value) when is_atom(key) do
    put_in(response.private[key], value)
  end

  @doc """
  Returns the values of the header specified by `key`.

  ## Examples

      iex> Req.Response.get_header(response, "content-type")
      ["application/json"]
  """
  @spec get_header(t(), binary()) :: [binary()]
  def get_header(%Req.Response{} = response, key) when is_binary(key) do
    for {^key, value} <- response.headers, do: value
  end

  @doc """
  Adds a new response header (`key`) if not present, otherwise replaces the
  previous value of that header with `value`.

  ## Examples

      iex> Req.Response.put_header(response, "content-type", "application/json").headers
      [{"content-type", "application/json"}]

  """
  @spec put_header(t(), binary(), binary()) :: t()
  def put_header(%Req.Response{} = response, key, value)
      when is_binary(key) and is_binary(value) do
    %{response | headers: List.keystore(response.headers, key, 0, {key, value})}
  end
end
