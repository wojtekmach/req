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

  defstruct [
    :status,
    headers: [],
    body: "",
    private: %{}
  ]

  @doc """
  Gets the value for a specific private `key`.
  """
  def get_private(response, key, default \\ nil) when is_atom(key) do
    Map.get(response.private, key, default)
  end

  @doc """
  Assigns a private `key` to `value`.
  """
  def put_private(response, key, value) when is_atom(key) do
    put_in(response.private[key], value)
  end

  @doc """
  Returns the values of the header specified by `key`.

  ## Examples

      iex> Req.Response.get_header(response, "content-type")
      ["application/json"]
  """
  def get_header(%Req.Response{} = response, key) when is_binary(key) do
    for {^key, value} <- response.headers, do: value
  end
end
