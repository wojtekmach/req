defmodule Req.Request do
  @moduledoc """
  The request pipeline struct.

  Fields:

    * `:method` - the HTTP request method

    * `:url` - the HTTP request URL

    * `:headers` - the HTTP request headers

    * `:body` - the HTTP request body

    * `:adapter` - a request step that makes the actual HTTP request

    * `:unix_socket` - if set, connect through the given UNIX domain socket

    * `:halted` - whether the request pipeline is halted. See `halt/1`

    * `:request_steps` - the list of request steps

    * `:response_steps` - the list of response steps

    * `:error_steps` - the list of error steps

    * `:private` - a map reserved for libraries and frameworks to use.
      Prefix the keys with the name of your project to avoid any future
      conflicts. Only accepts `t:atom/0` keys.
  """

  defstruct [
    :method,
    :url,
    headers: [],
    body: "",
    adapter: {Req, :run_finch, []},
    unix_socket: nil,
    halted: false,
    request_steps: [],
    response_steps: [],
    error_steps: [],
    private: %{}
  ]

  @doc """
  Sets the request adapter.

  Adapter is a request step that is making the actual HTTP request. It is
  automatically executed as the very last step in the request pipeline.

  The default adapter is using `Finch`.
  """
  def put_adapter(request, adapter) do
    %{request | adapter: adapter}
  end

  @doc """
  Gets the value for a specific private `key`.
  """
  def get_private(request, key, default \\ nil) when is_atom(key) do
    Map.get(request.private, key, default)
  end

  @doc """
  Assigns a private `key` to `value`.
  """
  def put_private(request, key, value) when is_atom(key) do
    put_in(request.private[key], value)
  end

  @doc """
  Halts the request pipeline preventing any further steps from executing.
  """
  def halt(request) do
    %{request | halted: true}
  end
end
