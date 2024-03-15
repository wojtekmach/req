defmodule Req.Test do
  @moduledoc """
  Functions for creating test stubs.

  > Stubs provide canned answers to calls made during the test, usually not responding at all to
  > anything outside what's programmed in for the test.
  >
  > ["Mocks Aren't Stubs" by Martin Fowler](https://martinfowler.com/articles/mocksArentStubs.html#TheDifferenceBetweenMocksAndStubs)

  Req already has built-in support for stubs via `:plug`, `:adapter`, and (indirectly) `:base_url`
  options. This module enhances these capabilities by providing:

    * Stub any value with [`Req.Test.stub(name, value)`](`stub/2`) and access it with
      [`Req.Test.stub(name)`](`stub/1`). These functions can be used in concurrent tests.

    * Access plug stubs with `plug: {Req.Test, name}`.

    * Easily create JSON responses for Plug stubs with [`Req.Test.json(conn, body)`](`json/2`).

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

  ### Concurrency and Allowances

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

  ### Broadway

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

  @ownership Req.Ownership

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
  Returns the stub created by `stub/2`.
  """
  def stub(stub_name) do
    case NimbleOwnership.fetch_owner(@ownership, callers(), stub_name) do
      {:ok, owner} when is_pid(owner) ->
        %{^stub_name => value} = NimbleOwnership.get_owned(@ownership, owner)
        value

      :error ->
        raise "cannot find stub #{inspect(stub_name)} in process #{inspect(self())}"
    end
  end

  @doc """
  Creates a stub with given `name` and `value`.

  This function allows stubbing _any_ value and later access it with `stub/1`. It is safe to use
  in concurrent tests.

  See [module documentation](`Req.Test`) for more examples.

  ## Examples

      iex> Req.Test.stub(MyStub, :foo)
      iex> Req.Test.stub(MyStub)
      :foo
      iex> Task.async(fn -> Req.Test.stub(MyStub) end) |> Task.await()
      :foo
  """
  def stub(stub_name, value) do
    NimbleOwnership.get_and_update(@ownership, self(), stub_name, fn _ -> {:ok, value} end)
  end

  @doc """
  Allows `pid_to_allow` to access `stub_name` provided that `owner` is already allowed.
  """
  def allow(stub_name, owner, pid_to_allow) when is_pid(owner) do
    NimbleOwnership.allow(@ownership, owner, pid_to_allow, stub_name)
  end

  defp callers do
    [self() | Process.get(:"$callers") || []]
  end

  @doc false
  def init(stub_name) do
    stub_name
  end

  @doc false
  def call(conn, stub_name) do
    case stub(stub_name) do
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
