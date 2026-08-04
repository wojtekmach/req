{:ok, _resp, acc} =
  Req.stream(
    "https://api.openai.com/v1/chat/completions",
    %{request_id: nil, total_tokens: 0},
    fn
      %{data: "[DONE]"}, _resp, acc ->
        {:cont, acc}

      %{data: data}, resp, acc ->
        [request_id] = Req.Response.get_header(resp, "x-request-id")
        acc = put_in(acc.request_id, request_id)

        case JSON.decode!(data) do
          %{"choices" => [%{"delta" => %{"content" => chunk}} | _]} ->
            IO.write(chunk)
            {:cont, acc}

          %{"usage" => %{} = usage} ->
            {:cont, put_in(acc.total_tokens, usage["total_tokens"])}

          _other ->
            {:cont, acc}
        end
    end,
    auth: {:bearer, System.fetch_env!("OPENAI_API_KEY")},
    json: %{
      model: "gpt-4o-mini",
      messages: [%{role: "user", content: "Write a haiku about Elixir."}],
      stream: true,
      stream_options: %{include_usage: true}
    }
  )

IO.puts("\n")
dbg(acc)
