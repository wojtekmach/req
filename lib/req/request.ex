defmodule Req.Request do
  defstruct [
    :method,
    :uri,
    :headers,
    body: "",
    halted: false,
    request_steps: [],
    response_steps: [],
    error_steps: [],
    private: %{}
  ]

  @doc """
  Gets the value for a specific private `key`.
  """
  def get_private(request, key, default \\ nil) do
    Map.get(request.private, key, default)
  end

  @doc """
  Assigns a new private `key` and `value`.
  """
  def put_private(request, key, value) do
    update_in(request.private, &Map.put(&1, key, value))
  end

  @doc """
  Halts the request pipeline preventing any further steps from executing.
  """
  def halt(request) do
    %{request | halted: true}
  end
end
