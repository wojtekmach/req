defmodule Main do
  def main do
    calculator = MCP.connect("http://calculator", plug: Calculator)
    %{"tools" => mcp_tools} = MCP.rpc!(calculator, "tools/list", %{})

    tools =
      for %{"name" => name, "description" => desc, "inputSchema" => schema} <- mcp_tools do
        %{type: "function", name: name, description: desc, parameters: schema}
      end

    api_key = System.fetch_env!("OPENAI_API_KEY")
    openai = Req.new(base_url: "https://api.openai.com/v1", auth: {:bearer, api_key})

    %{"id" => id, "output" => output} =
      Req.post!(
        openai,
        url: "/responses",
        json: %{
          input: "What is 1 + 2?",
          model: "gpt-4o-mini",
          tools: tools
        }
      ).body

    %{"name" => name, "arguments" => args, "call_id" => call_id} =
      Enum.find(output, &(&1["type"] == "function_call"))

    %{"content" => [%{"type" => "text", "text" => text}]} =
      MCP.call_tool!(calculator, name, JSON.decode!(args), fn %{"params" => %{"data" => data}} ->
        IO.puts("MCP server says: #{data}")
      end)

    input = [%{type: "function_call_output", call_id: call_id, output: text}]

    {:ok, _} =
      Req.stream(
        openai,
        nil,
        fn %{event: event, data: data}, _resp, acc ->
          if event == "response.output_text.delta" do
            IO.write(JSON.decode!(data)["delta"])
          end

          {:ok, acc}
        end,
        url: "/responses",
        json: %{
          input: input,
          model: "gpt-4o-mini",
          previous_response_id: id,
          stream: true,
          tools: tools
        }
      )

    IO.puts("")
  end
end

defmodule Calculator do
  @tools [
    %{
      name: "add",
      description: "Adds two numbers.",
      inputSchema: %{type: "object", properties: %{a: %{type: "number"}, b: %{type: "number"}}}
    }
  ]

  def init(options), do: options

  def call(conn, _options), do: do_call(conn, conn.params)

  defp do_call(conn, %{"method" => "notifications/" <> _}) do
    Plug.Conn.send_resp(conn, 202, "")
  end

  defp do_call(conn, %{"method" => "initialize"}) do
    info = %{name: "Calculator"}
    result = %{protocolVersion: "2025-06-18", capabilities: %{tools: %{}}, serverInfo: info}
    MCP.reply(conn, result)
  end

  defp do_call(conn, %{"method" => "tools/list"}) do
    MCP.reply(conn, %{tools: @tools})
  end

  defp do_call(conn, %{"method" => "tools/call", "params" => %{"name" => "add"} = params}) do
    %{"a" => a, "b" => b} = params["arguments"]

    conn
    |> Plug.Conn.put_resp_content_type("text/event-stream")
    |> Plug.Conn.send_chunked(200)
    |> MCP.notify("adding #{a} and #{b}...")
    |> MCP.reply_sse(%{content: [%{type: "text", text: to_string(a + b)}]})
  end
end

defmodule MCP do
  ## Client

  def connect(url, options \\ []) do
    req = Req.new(url: url, headers: [accept: "application/json, text/event-stream"])
    req = Req.merge(req, options)
    init = %{protocolVersion: "2025-06-18", capabilities: %{}, clientInfo: %{name: "Req"}}
    rpc!(req, "initialize", init)
    Req.post!(req, json: %{jsonrpc: "2.0", method: "notifications/initialized"})
    req
  end

  def rpc!(req, method, params) do
    Req.post!(req,
      json: %{jsonrpc: "2.0", id: System.unique_integer(), method: method, params: params}
    ).body["result"]
  end

  def call_tool!(req, name, args, on_notification) do
    id = System.unique_integer()

    {:ok, result} =
      Req.stream(
        req,
        nil,
        fn %{data: data}, _resp, acc ->
          case JSON.decode!(data) do
            %{"method" => "notifications/" <> _} = notification ->
              on_notification.(notification)
              {:ok, acc}

            %{"id" => ^id, "result" => result} ->
              {:ok, result}
          end
        end,
        json: %{
          jsonrpc: "2.0",
          id: id,
          method: "tools/call",
          params: %{name: name, arguments: args}
        }
      )

    result
  end

  ## Server

  def notify(conn, text) do
    params = %{level: "info", data: text}
    sse(conn, %{jsonrpc: "2.0", method: "notifications/message", params: params})
  end

  def reply(conn, result) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(
      200,
      JSON.encode!(%{jsonrpc: "2.0", id: conn.params["id"], result: result})
    )
  end

  def reply_sse(conn, result) do
    sse(conn, %{jsonrpc: "2.0", id: conn.params["id"], result: result})
  end

  defp sse(conn, message) do
    {:ok, conn} = Plug.Conn.chunk(conn, ["data: ", JSON.encode_to_iodata!(message), "\n\n"])
    conn
  end
end

Main.main()
