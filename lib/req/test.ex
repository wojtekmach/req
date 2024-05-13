defmodule Req.Test do
  @moduledoc """
  Functions for creating test stubs.

  > Stubs provide canned answers to calls made during the test, usually not responding at all to
  > anything outside what's programmed in for the test.
  >
  > ["Mocks Aren't Stubs" by Martin Fowler](https://martinfowler.com/articles/mocksArentStubs.html#TheDifferenceBetweenMocksAndStubs)

  Req already has built-in support for different variants of stubs via `:plug`, `:adapter`,
  and (indirectly) `:base_url` options. This module enhances these capabilities by providing:

    * Stubbing request handling with [`Req.Test.stub(name, handler)`](`stub/2`) (which can be
      used in concurrent tests).

    * Providing a plug that you can pass as `plug: {Req.Test, name}`, so that requests
      go through the stubbed request flow you defined with `stub/2`. This works because
      `Req.Test` itself is a plug whose job is to fetch the stubbed handler under `name`.

    * Easily create JSON responses for plug stubs with [`Req.Test.json(conn, body)`](`json/2`).

  This module bases stubs on the ownership model of
  [nimble_ownership](https://hex.pm/packages/nimble_ownership), also used by
  [Mox](https://hex.pm/packages/mox) for example. This allows `Req.Test` to be used in concurrent
  tests.

  ## Example

  Imagine we're building an app that displays weather for a given location using an HTTP weather
  service:

      defmodule MyApp.Weather do
        def get_rating(location) do
          case get_temperature(location) do
            {:ok, %{status: 200, body: %{"celsius" => celsius}}} ->
              cond do
                celsius < 18.0 -> {:ok, :too_cold}
                celsius < 30.0 -> {:ok, :nice}
                true -> {:ok, :too_hot}
              end

            _ ->
              :error
          end
        end

        def get_temperature(location) do
          [
            base_url: "https://weather-service"
          ]
          |> Keyword.merge(Application.get_env(:myapp, :weather_req_options, []))
          |> Req.request()
        end
      end

  We configure it for production:

      # config/runtime.exs
      config :myapp, weather_req_options: [
        auth: {:bearer, System.fetch_env!("MYAPP_WEATHER_API_KEY")}
      ]

  In tests, instead of hitting the network, we make the request against
  a [plug](`Req.Steps.put_plug/1`) _stub_ named `MyApp.Weather`:

      # config/test.exs
      config :myapp, weather_req_options: [
        plug: {Req.Test, MyApp.Weather}
      ]

  Now we can control our stubs **in concurrent tests**:

      use ExUnit.Case, async: true

      test "nice weather" do
        Req.Test.stub(MyApp.Weather, fn conn ->
          Req.Test.json(conn, %{"celsius" => 25.0})
        end)

        assert MyApp.Weather.get_rating("Krakow, Poland") == {:ok, :nice}
      end

  ## Concurrency and Allowances

  The example above works in concurrent tests because `MyApp.Weather.get_rating/1` calls
  directly to `Req.request/1` *in the same process*. It also works in many cases where the
  request happens in a spawned process, such as a `Task`, `GenServer`, and more.

  However, if you are encountering issues with stubs not being available in spawned processes,
  it's likely that you'll need **explicit allowances**. For example, if
  `MyApp.Weather.get_rating/1` was calling `Req.request/1` in a process spawned with `spawn/1`,
  the stub would not be available in the spawned process:

      # With code like this, the stub would not be available in the spawned task:
      def get_rating_async(location) do
        spawn(fn -> get_rating(location) end)
      end

  To make stubs defined in the test process available in other processes, you can use
  `allow/3`. For example, imagine that the call to `MyApp.Weather.get_rating/1`
  was happening in a spawned GenServer:

      test "nice weather" do
        {:ok, pid} = start_gen_server(...)

        Req.Test.stub(MyApp.Weather, fn conn ->
          Req.Test.json(conn, %{"celsius" => 25.0})
        end)

        Req.Test.allow(MyApp.Weather, self(), pid)

        assert get_weather(pid, "Krakow, Poland") == {:ok, :nice}
      end

  ## Broadway

  If you're using `Req.Test` with [Broadway](https://hex.pm/broadway), you may need to use
  `allow/3` to make stubs available in the Broadway processors. A great way to do that is
  to hook into the [Telemetry](https://hex.pm/telemetry) events that Broadway publishes to
  manually allow the processors and batch processors to access the stubs. This approach is
  similar to what is [documented in Broadway
  itself](https://hexdocs.pm/broadway/Broadway.html#module-testing-with-ecto).

  First, you should add the test PID (which is allowed to use the Req stub) to the metadata
  for the test events you're publishing:

      Broadway.test_message(MyApp.Pipeline, message, metadata: %{req_stub_owner: self()})

  Then, you'll need to define a test helper to hook into the Telemetry events. For example,
  in your `test/test_helper.exs` file:

      defmodule BroadwayReqStubs do
        def attach(stub) do
          events = [
            [:broadway, :processor, :start],
            [:broadway, :batch_processor, :start],
          ]

          :telemetry.attach_many({__MODULE__, stub}, events, &__MODULE__.handle_event/4, %{stub: stub})
        end

        def handle_event(_event_name, _event_measurement, %{messages: messages}, %{stub: stub}) do
          with [%Broadway.Message{metadata: %{req_stub_owner: pid}} | _] <- messages do
            :ok = Req.Test.allow(stub, pid, self())
          end

          :ok
        end
      end

  Last but not least, attach the helper in your `test/test_helper.exs`:

      BroadwayReqStubs.attach(MyStub)

  """

  require Logger

  @typedoc """
  A stub is an atom that scopes stubbed requests.

  A common choice for this is the module name for the Req-based client that you
  are using `Req.Test` for. For example, if you are using `MyApp.Weather` as
  your client, you can use `MyApp.Weather` as the stub name in functions
  like `stub/1` and `stub/2`.
  """
  @typedoc since: "0.4.15"
  @opaque stub() :: atom()

  if Code.ensure_loaded?(Plug.Conn) do
    @type plug() ::
            {module(), [term()]}
            | module()
            | (Plug.Conn.t() -> Plug.Conn.t())
            | (Plug.Conn.t(), term() -> Plug.Conn.t())
  else
    @type plug() ::
            {module(), [term()]}
            | module()
            | (term() -> term())
            | (term(), term() -> term())
  end

  @ownership Req.Test.Ownership

  @doc """
  Sends JSON response.

  ## Examples

      iex> plug = fn conn ->
      ...>   Req.Test.json(conn, %{celsius: 25.0})
      ...> end
      iex>
      iex> resp = Req.get!(plug: plug)
      iex> resp.headers["content-type"]
      ["application/json; charset=utf-8"]
      iex> resp.body
      %{"celsius" => 25.0}

  """
  if Code.ensure_loaded?(Plug.Conn) do
    @spec json(Plug.Conn.t(), term()) :: Plug.Conn.t()
  end

  def json(conn, data)

  if Code.ensure_loaded?(Plug.Test) do
    def json(%Plug.Conn{} = conn, data) do
      send_resp(conn, conn.status || 200, "application/json", Jason.encode_to_iodata!(data))
    end

    defp send_resp(conn, default_status, default_content_type, body) do
      conn
      |> ensure_resp_content_type(default_content_type)
      |> Plug.Conn.send_resp(conn.status || default_status, body)
    end

    defp ensure_resp_content_type(%Plug.Conn{resp_headers: resp_headers} = conn, content_type) do
      if List.keyfind(resp_headers, "content-type", 0) do
        conn
      else
        content_type = content_type <> "; charset=utf-8"
        %Plug.Conn{conn | resp_headers: [{"content-type", content_type} | resp_headers]}
      end
    end
  else
    def json(_conn, _data) do
      Logger.error("""
      Could not find plug dependency.

      Please add :plug to your dependencies:

          {:plug, "~> 1.0"}
      """)

      raise "missing plug dependency"
    end
  end

  @doc """
  Simulates a network transport error.

  ## Examples

      iex> plug = fn conn ->
      ...>   Req.Test.transport_error(conn, :timeout)
      ...> end
      iex>
      iex> Req.get(plug: plug, retry: false)
      {:error, %Req.TransportError{reason: :timeout}}

  """
  def transport_error(conn, reason)

  if Code.ensure_loaded?(Plug.Conn) do
    @spec transport_error(Plug.Conn.t(), reason :: atom()) :: Plug.Conn.t()
    def transport_error(%Plug.Conn{} = conn, reason) do
      validate_transport_error!(reason)
      exception = Req.TransportError.exception(reason: reason)
      put_in(conn.private[:req_test_exception], exception)
    end

    defp validate_transport_error!(:protocol_not_negotiated), do: :ok
    defp validate_transport_error!({:bad_alpn_protocol, _}), do: :ok
    defp validate_transport_error!(:closed), do: :ok
    defp validate_transport_error!(:timeout), do: :ok

    defp validate_transport_error!(reason) do
      case :ssl.format_error(reason) do
        ~c"Unexpected error:" ++ _ ->
          raise ArgumentError, "unexpected Req.TransportError reason: #{inspect(reason)}"

        _ ->
          :ok
      end
    end
  else
    def transport_error(_conn, _reason) do
      Logger.error("""
      Could not find plug dependency.

      Please add :plug to your dependencies:

          {:plug, "~> 1.0"}
      """)

      raise "missing plug dependency"
    end
  end

  @deprecated "Don't manually fetch stubs. See the documentation for Req.Test instead."
  def stub(name) do
    __fetch_stub__(name)
  end

  def __fetch_stub__(name) do
    case Req.Test.Ownership.fetch_owner(@ownership, callers(), name) do
      {:ok, owner} when is_pid(owner) ->
        result =
          Req.Test.Ownership.get_and_update(@ownership, owner, name, fn
            %{expectations: [value | rest]} = map ->
              {{:ok, value}, put_in(map[:expectations], rest)}

            %{stub: value} = map ->
              {{:ok, value}, map}

            %{expectations: []} = map ->
              {{:error, :no_expectations_and_no_stub}, map}
          end)

        case result do
          {:ok, {:ok, value}} ->
            value

          {:ok, {:error, :no_expectations_and_no_stub}} ->
            raise "no stub or expectations for #{inspect(name)}"
        end

      :error ->
        raise "cannot find stub #{inspect(name)} in process #{inspect(self())}"
    end
  end

  defguardp is_plug(value)
            when is_function(value, 1) or is_atom(value) or
                   (is_tuple(value) and tuple_size(value) == 2 and is_atom(elem(value, 0)))

  @doc """
  Registers a stub with the given request handler for the given `name`.

  This function is safe to use in concurrent tests. `name` is any term that can identify
  the stub or mock. In general, this is going to be something like the name of the module
  that calls Req, in order to "scope" the stub to that module.

  See [module documentation](`Req.Test`) for more examples.

  The `request_handler` should be a plug in the form of:

    * A function that takes a `Plug.Conn` and returns a `Plug.Conn`.
    * A `module` plug, equivalent to `{module, []}`.
    * A `{module, args}` plug, equivalent to defining the `Plug` module with `init/1` and
      `call/2`.

  ## Examples

      iex> Req.Test.stub(MyStub, fn conn ->
      ...>   send(self(), :req_happened)
      ...>   Req.Test.json(conn, %{})
      ...> end)
      :ok
      iex> Req.get!(plug: {Req.Test, MyStub}).body
      %{}
      iex> receive do
      ...>   :req_happened -> :ok
      ...> end
      :ok

  """
  @spec stub(stub(), plug()) :: :ok | {:error, Exception.t()}
  def stub(name, plug) when is_plug(plug) do
    result =
      Req.Test.Ownership.get_and_update(@ownership, self(), name, fn map_or_nil ->
        {:ok, put_in(map_or_nil || %{}, [:stub], plug)}
      end)

    case result do
      {:ok, :ok} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  @doc """
  Creates an expectation with the given `name` and `value`, expected to be fetched at
  most `n` times.

  This function allows you to expect a `n` number of request and handle them via the given
  `plug`. It is safe to use in concurrent tests. If you fetch the value under `name`
  more than `n` times, this function raises a `RuntimeError`.

  ## Examples

      iex> Req.Test.expect(MyStub, 2, Plug.Head)
      iex> Req.request!(plug: {Req.Test, MyStub})
      iex> Req.request!(plug: {Req.Test, MyStub})
      iex> Req.request!(plug: {Req.Test, MyStub})
      ** (RuntimeError) no stub or expectations for MyStub

  """
  @doc since: "0.4.15"
  @spec expect(stub(), pos_integer(), plug()) :: :ok | {:error, Exception.t()}
  def expect(name, n \\ 1, plug) when is_integer(n) and n > 0 do
    plugs = List.duplicate(plug, n)

    result =
      Req.Test.Ownership.get_and_update(@ownership, self(), name, fn map_or_nil ->
        {:ok, Map.update(map_or_nil || %{}, :expectations, plugs, &(plugs ++ &1))}
      end)

    case result do
      {:ok, :ok} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  @doc """
  Allows `pid_to_allow` to access `name` provided that `owner` is already allowed.
  """
  @spec allow(stub(), pid(), pid() | (-> pid())) :: :ok | {:error, Exception.t()}
  def allow(name, owner, pid_to_allow) when is_pid(owner) do
    Req.Test.Ownership.allow(@ownership, owner, pid_to_allow, name)
  end

  @doc """
  Sets the `Req.Test` mode to "global", meaning that the stubs are shared across all tests
  and cannot be used concurrently.
  """
  @doc since: "0.5.0"
  @spec set_req_test_to_shared(ex_unit_context :: term()) :: :ok
  def set_req_test_to_shared(_context \\ %{}) do
    Req.Test.Ownership.set_mode_to_shared(@ownership, self())
  end

  @doc """
  Sets the `Req.Test` mode to "private", meaning that stubs can be shared across
  tests concurrently.
  """
  @doc since: "0.5.0"
  @spec set_req_test_to_private(ex_unit_context :: term()) :: :ok
  def set_req_test_to_private(_context \\ %{}) do
    Req.Test.Ownership.set_mode_to_private(@ownership)
  end

  @doc """
  Sets the `Req.Test` mode based on the given `ExUnit` context.

  This works as a ExUnit callback:

      setup :set_req_test_from_context

  """
  @doc since: "0.5.0"
  @spec set_req_test_from_context(ex_unit_context :: term()) :: :ok
  def set_req_test_from_context(_context \\ %{})

  def set_req_test_from_context(%{async: true} = context), do: set_req_test_to_private(context)
  def set_req_test_from_context(context), do: set_req_test_to_shared(context)

  @doc """
  Sets a ExUnit callback to verify the expectations on exit.

  Similar to calling `verify!/0` at the end of your test.
  """
  @doc since: "0.5.0"
  @spec verify_on_exit!(term()) :: :ok
  def verify_on_exit!(_context \\ %{}) do
    pid = self()
    Req.Test.Ownership.set_owner_to_manual_cleanup(@ownership, pid)

    ExUnit.Callbacks.on_exit(Mox, fn ->
      verify(pid, :all)
      Req.Test.Ownership.cleanup_owner(@ownership, pid)
    end)
  end

  @doc """
  Verifies that all the plugs expected to be executed within any scope have been executed.
  """
  @doc since: "0.5.0"
  @spec verify!() :: :ok
  def verify! do
    verify(self(), :all)
  end

  @doc """
  Verifies that all the plugs expected to be executed within the scope of `name` have been
  executed.
  """
  @doc since: "0.5.0"
  @spec verify!(stub()) :: :ok
  def verify!(name) do
    verify(self(), name)
  end

  defp verify(owner_pid, mock_or_all) do
    messages =
      for {name, stubs_and_expecs} <-
            Req.Test.Ownership.get_owned(@ownership, owner_pid, _default = %{}, 5000),
          name == mock_or_all or mock_or_all == :all,
          pending_count = stubs_and_expecs |> Map.get(:expectations, []) |> length(),
          pending_count > 0 do
        "  * expected #{inspect(name)} to be still used #{pending_count} more times"
      end

    if messages != [] do
      raise "error while verifying Req.Test expectations for #{inspect(owner_pid)}:\n\n" <>
              Enum.join(messages, "\n")
    end

    :ok
  end

  ## Helpers

  defp callers do
    [self() | Process.get(:"$callers") || []]
  end

  ## Plug callbacks

  if Code.ensure_loaded?(Plug) do
    @behaviour Plug
  end

  @doc false
  def init(name) do
    name
  end

  @doc false
  def call(conn, name) do
    case __fetch_stub__(name) do
      fun when is_function(fun) ->
        fun.(conn)

      module when is_atom(module) ->
        module.call(conn, module.init([]))

      {module, options} when is_atom(module) ->
        module.call(conn, module.init(options))

      other ->
        raise """
        expected stub to be one of:

          * 0-arity function
          * module
          * {module, options}

        got: #{inspect(other)}\
        """
    end
  end
end
