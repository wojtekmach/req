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

  @doc """
  Returns a new response.
  """
  @spec new(options :: keyword()) :: t()
  def new(options \\ []) do
    struct!(__MODULE__, options)
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
