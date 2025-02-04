# Vendored from nimble_ownership v1.0.1, replacing NimbleOwnership.Error with
# Req.Test.OwnershipError.
#
# Check changes with:
#
#     git diff --no-index lib/req/test/ownership.ex ../nimble_ownership/lib/nimble_ownership.ex
defmodule Req.Test.Ownership do
  @moduledoc false

  defguardp is_timeout(val) when (is_integer(val) and val > 0) or val == :infinity

  use GenServer

  alias Req.Test.OwnershipError, as: Error

  @typedoc "Ownership server."
  @type server() :: GenServer.server()

  @typedoc "Arbitrary key."
  @type key() :: term()

  @typedoc "Arbitrary metadata associated with an owned `t:key/0`."
  @type metadata() :: term()

  @genserver_opts [
    :name,
    :timeout,
    :debug,
    :spawn_opt,
    :hibernate_after
  ]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options \\ []) when is_list(options) do
    {genserver_opts, other_opts} = Keyword.split(options, @genserver_opts)

    if other_opts != [] do
      raise ArgumentError, "unknown options: #{inspect(Keyword.keys(other_opts))}"
    end

    GenServer.start_link(__MODULE__, [], genserver_opts)
  end

  @spec allow(server(), pid(), pid() | (-> resolved_pid), key()) ::
          :ok | {:error, Error.t()}
        when resolved_pid: pid() | [pid()]
  def allow(ownership_server, pid_with_access, pid_to_allow, key, timeout \\ 5000)
      when is_pid(pid_with_access) and (is_pid(pid_to_allow) or is_function(pid_to_allow, 0)) and
             is_timeout(timeout) do
    GenServer.call(ownership_server, {:allow, pid_with_access, pid_to_allow, key}, timeout)
  end

  @spec get_and_update(server(), pid(), key(), fun, timeout()) ::
          {:ok, get_value} | {:error, Error.t()}
        when fun: (nil | metadata() -> {get_value, updated_metadata :: metadata()}),
             get_value: term()
  def get_and_update(ownership_server, owner_pid, key, fun, timeout \\ 5000)
      when is_pid(owner_pid) and is_function(fun, 1) and is_timeout(timeout) do
    case GenServer.call(ownership_server, {:get_and_update, owner_pid, key, fun}, timeout) do
      {:ok, get_value} -> {:ok, get_value}
      {:error, %Error{} = error} -> {:error, error}
      {:__raise__, error} when is_exception(error) -> raise error
    end
  end

  @spec fetch_owner(server(), [pid(), ...], key(), timeout()) ::
          {:ok, owner :: pid()}
          | {:shared_owner, shared_owner :: pid()}
          | :error
  def fetch_owner(ownership_server, [_ | _] = callers, key, timeout \\ 5000)
      when is_timeout(timeout) do
    GenServer.call(ownership_server, {:fetch_owner, callers, key}, timeout)
  end

  @spec get_owned(server(), pid(), default, timeout()) :: %{key() => metadata()} | default
        when default: term()
  def get_owned(ownership_server, owner_pid, default \\ nil, timeout \\ 5000)
      when is_pid(owner_pid) and is_timeout(timeout) do
    GenServer.call(ownership_server, {:get_owned, owner_pid, default}, timeout)
  end

  @spec set_mode_to_private(server()) :: :ok
  def set_mode_to_private(ownership_server) do
    GenServer.call(ownership_server, {:set_mode, :private})
  end

  @spec set_mode_to_shared(server(), pid()) :: :ok
  def set_mode_to_shared(ownership_server, shared_owner) when is_pid(shared_owner) do
    GenServer.call(ownership_server, {:set_mode, {:shared, shared_owner}})
  end

  @spec set_owner_to_manual_cleanup(server(), pid()) :: :ok
  def set_owner_to_manual_cleanup(ownership_server, owner_pid) do
    GenServer.call(ownership_server, {:set_owner_to_manual_cleanup, owner_pid})
  end

  @spec cleanup_owner(server(), pid()) :: :ok
  def cleanup_owner(ownership_server, owner_pid) when is_pid(owner_pid) do
    GenServer.call(ownership_server, {:cleanup_owner, owner_pid})
  end

  ## State

  defstruct [
    # The mode can be either :private, or {:shared, shared_owner_pid}.
    mode: :private,

    # This is a map of %{owner_pid => %{key => metadata}}. Its purpose is to track the metadata
    # under each key that a owner owns.
    owners: %{},

    # This tracks what to do when each owner goes down. It's a map of
    # %{owner_pid => :auto | :manual}.
    owner_cleanup: %{},

    # This is a map of %{allowed_pid => %{key => owner_pid}}. Its purpose is to track the keys
    # that a PID is allowed to access, alongside which the owner of those keys is.
    allowances: %{},

    # This is used to track which PIDs we're monitoring, to avoid double-monitoring.
    monitored_pids: MapSet.new()
  ]

  ## Callbacks

  @impl true
  def init([]) do
    {:ok, %__MODULE__{}}
  end

  @impl true
  def handle_call(call, from, state)

  def handle_call(
        {:allow, _pid_with_access, _pid_to_allow, key},
        _from,
        %__MODULE__{mode: {:shared, _shared_owner}} = state
      ) do
    error = %Error{key: key, reason: :cant_allow_in_shared_mode}
    {:reply, {:error, error}, state}
  end

  def handle_call(
        {:allow, pid_with_access, pid_to_allow, key},
        _from,
        %__MODULE__{mode: :private} = state
      ) do
    if state.owners[pid_to_allow][key] do
      error = %Error{key: key, reason: :already_an_owner}
      throw({:reply, {:error, error}, state})
    end

    owner_pid =
      cond do
        owner_pid = state.allowances[pid_with_access][key] ->
          owner_pid

        _meta = state.owners[pid_with_access][key] ->
          pid_with_access

        true ->
          throw({:reply, {:error, %Error{key: key, reason: :not_allowed}}, state})
      end

    case state.allowances[pid_to_allow][key] do
      # There's already another owner PID that is allowing "pid_to_allow" to use "key".
      other_owner_pid when is_pid(other_owner_pid) and other_owner_pid != owner_pid ->
        error = %Error{key: key, reason: {:already_allowed, other_owner_pid}}
        {:reply, {:error, error}, state}

      # "pid_to_allow" is already allowed access to "key" through the same "owner_pid",
      # so this is a no-op.
      ^owner_pid ->
        {:reply, :ok, state}

      nil ->
        state =
          state
          |> maybe_monitor_pid(pid_with_access)
          |> put_in([Access.key!(:allowances), Access.key(pid_to_allow, %{}), key], owner_pid)

        {:reply, :ok, state}
    end
  end

  def handle_call({:get_and_update, owner_pid, key, fun}, _from, %__MODULE__{} = state) do
    case state.mode do
      {:shared, shared_owner_pid} when shared_owner_pid != owner_pid ->
        error = %Error{key: key, reason: {:not_shared_owner, shared_owner_pid}}
        throw({:reply, {:error, error}, state})

      _ ->
        :ok
    end

    state = resolve_lazy_calls_for_key(state, key)

    if other_owner = state.allowances[owner_pid][key] do
      throw({:reply, {:error, %Error{key: key, reason: {:already_allowed, other_owner}}}, state})
    end

    case fun.(_meta_or_nil = state.owners[owner_pid][key]) do
      {get_value, new_meta} ->
        state = put_in(state, [Access.key!(:owners), Access.key(owner_pid, %{}), key], new_meta)

        # We should also monitor the new owner, if it hasn't already been monitored. That
        # can happen if that owner is already the owner of another key. We ALWAYS monitor,
        # so if owner_pid is already an owner we're already monitoring it.
        state =
          if not Map.has_key?(state.owner_cleanup, owner_pid) do
            _ref = Process.monitor(owner_pid)
            put_in(state.owner_cleanup[owner_pid], :auto)
          else
            state
          end

        {:reply, {:ok, get_value}, state}

      other ->
        message = """
        invalid return value from callback function. Expected nil or a tuple of the form \
        {get_value, update_value} (see the function's @spec), instead got: #{inspect(other)}\
        """

        {:reply, {:__raise__, %ArgumentError{message: message}}, state}
    end
  end

  def handle_call(
        {:fetch_owner, _callers, _key},
        _from,
        %__MODULE__{mode: {:shared, shared_owner_pid}} = state
      ) do
    {:reply, {:shared_owner, shared_owner_pid}, state}
  end

  def handle_call({:fetch_owner, callers, key}, _from, %__MODULE__{mode: :private} = state) do
    {owner, state} =
      case fetch_owner_once(state, callers, key) do
        nil ->
          state = resolve_lazy_calls_for_key(state, key)
          {fetch_owner_once(state, callers, key), state}

        owner ->
          {owner, state}
      end

    if is_nil(owner) do
      {:reply, :error, state}
    else
      {:reply, {:ok, owner}, state}
    end
  end

  def handle_call({:get_owned, owner_pid, default}, _from, %__MODULE__{} = state) do
    {:reply, state.owners[owner_pid] || default, state}
  end

  def handle_call({:set_mode, {:shared, shared_owner_pid}}, _from, %__MODULE__{} = state) do
    state = maybe_monitor_pid(state, shared_owner_pid)
    state = %{state | mode: {:shared, shared_owner_pid}}
    {:reply, :ok, state}
  end

  def handle_call({:set_mode, :private}, _from, %__MODULE__{} = state) do
    {:reply, :ok, %{state | mode: :private}}
  end

  def handle_call({:set_owner_to_manual_cleanup, owner_pid}, _from, %__MODULE__{} = state) do
    {:reply, :ok, put_in(state.owner_cleanup[owner_pid], :manual)}
  end

  def handle_call({:cleanup_owner, pid}, _from, %__MODULE__{} = state) do
    {:reply, :ok, pop_owner_and_clean_up_allowances(state, pid)}
  end

  @impl true
  def handle_info(msg, state)

  # The global owner went down, so we go back to private mode.
  def handle_info({:DOWN, _, _, down_pid, _}, %__MODULE__{mode: {:shared, down_pid}} = state) do
    {:noreply, %{state | mode: :private}}
  end

  # An owner went down, so we need to clean up all of its allowances as well as all its keys.
  def handle_info({:DOWN, _ref, _, down_pid, _}, state)
      when is_map_key(state.owners, down_pid) do
    case state.owner_cleanup[down_pid] || :auto do
      :manual ->
        {:noreply, state}

      :auto ->
        state = pop_owner_and_clean_up_allowances(state, down_pid)
        {:noreply, state}
    end
  end

  # A PID that we were monitoring went down. Let's just clean up all its allowances.
  def handle_info({:DOWN, _, _, down_pid, _}, state) do
    {_keys_and_values, state} = pop_in(state.allowances[down_pid])
    state = update_in(state.monitored_pids, &MapSet.delete(&1, down_pid))
    {:noreply, state}
  end

  ## Helpers

  defp pop_owner_and_clean_up_allowances(state, target_pid) do
    {_, state} = pop_in(state.owners[target_pid])
    {_, state} = pop_in(state.owner_cleanup[target_pid])

    allowances =
      Enum.reduce(state.allowances, state.allowances, fn {pid, allowances}, acc ->
        new_allowances =
          for {key, owner_pid} <- allowances,
              owner_pid != target_pid,
              into: %{},
              do: {key, owner_pid}

        Map.put(acc, pid, new_allowances)
      end)

    %{state | allowances: allowances}
  end

  defp maybe_monitor_pid(state, pid) do
    if pid in state.monitored_pids do
      state
    else
      Process.monitor(pid)
      update_in(state.monitored_pids, &MapSet.put(&1, pid))
    end
  end

  defp fetch_owner_once(state, callers, key) do
    Enum.find_value(callers, fn caller ->
      case state do
        %{owners: %{^caller => %{^key => _meta}}} -> caller
        %{allowances: %{^caller => %{^key => owner_pid}}} -> owner_pid
        _ -> nil
      end
    end)
  end

  defp resolve_lazy_calls_for_key(state, key) do
    updated_allowances =
      Enum.reduce(state.allowances, state.allowances, fn
        {fun, value}, allowances when is_function(fun, 0) and is_map_key(value, key) ->
          result =
            fun.()
            |> List.wrap()
            |> Enum.group_by(&is_pid/1)

          allowances =
            result
            |> Map.get(true, [])
            |> Enum.reduce(allowances, fn pid, allowances ->
              Map.update(allowances, pid, value, &Map.merge(&1, value))
            end)

          if Map.has_key?(allowances, false), do: Map.delete(allowances, fun), else: allowances

        _, allowances ->
          allowances
      end)

    %{state | allowances: updated_allowances}
  end
end
