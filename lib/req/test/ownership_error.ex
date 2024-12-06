# Vendored from nimble_ownership. See Req.Test.Ownership.
defmodule Req.Test.OwnershipError do
  defexception [:reason, :key]

  @impl true
  def message(%__MODULE__{key: key, reason: reason}) do
    format_reason(key, reason)
  end

  ## Helpers

  defp format_reason(key, {:already_allowed, other_owner_pid}) do
    "this PID is already allowed to access key #{inspect(key)} via other owner PID #{inspect(other_owner_pid)}"
  end

  defp format_reason(key, :not_allowed) do
    "this PID is not allowed to access key #{inspect(key)}"
  end

  defp format_reason(key, :already_an_owner) do
    "this PID is already an owner of key #{inspect(key)}"
  end

  defp format_reason(_key, {:not_shared_owner, pid}) do
    "#{inspect(pid)} is not the shared owner, so it cannot update keys"
  end

  defp format_reason(_key, :cant_allow_in_shared_mode) do
    "cannot allow PIDs in shared mode"
  end
end
