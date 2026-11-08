# Run with: mix run --no-start scripts/verify_local.exs
# Requires both local models in Ollama and a CUDA-enabled EXLA build.
alias Ragex.Embeddings.Bumblebee, as: Embeddings
alias Yoke.Client.DeepSeekAPI

Logger.configure(level: :info)
Application.put_env(:ragex, :exla_client, :cuda)
Yoke.CLI.Main.configure_exla()
for app <- [:req, :bumblebee, :exla], do: Application.ensure_all_started(app)
{:ok, embedding_pid} = Embeddings.start_link()
{:ok, warm} = Embeddings.embed_batch(List.duplicate("def hello, do: :world", 32))
true = length(warm) == 32
serving = :sys.get_state(embedding_pid).serving
true = serving.defn_options[:client] == :cuda
IO.puts("Bumblebee ready: CUDA, 32-item batch, #{length(hd(warm))} dimensions")

tools = [
  %{
    name: "add_numbers",
    description: "Add two integers. Always use this tool for addition.",
    parameters: %{
      "type" => "object",
      "properties" => %{"a" => %{"type" => "integer"}, "b" => %{"type" => "integer"}},
      "required" => ["a", "b"]
    }
  }
]

for provider <- ["local", "local-qwen"] do
  opts = Yoke.Provider.resolve(provider: provider, mock: false, max_tokens: 256)
  IO.puts("Testing " <> Yoke.Provider.describe(opts))

  messages = [
    %{
      "role" => "system",
      "content" => "Use add_numbers to calculate sums. After the result, answer briefly."
    },
    %{"role" => "user", "content" => "Use the add_numbers tool to add 17 and 23."}
  ]

  {:ok, first} = DeepSeekAPI.chat_completion(messages, tools, opts)
  [call] = first.tool_calls
  "add_numbers" = call.name
  %{"a" => 17, "b" => 23} = call.arguments

  assistant = %{
    "role" => "assistant",
    "content" => first.content || "",
    "tool_calls" => [
      %{
        "id" => call.id,
        "type" => "function",
        "function" => %{"name" => call.name, "arguments" => Yoke.Json.encode!(call.arguments)}
      }
    ]
  }

  followup =
    messages ++ [assistant, %{"role" => "tool", "tool_call_id" => call.id, "content" => "40"}]

  embedding_task =
    Task.async(fn ->
      # Execute the CUDA serving directly so a CPU fallback cannot hide failure.
      for _ <- 1..4, do: Nx.Serving.run(serving, List.duplicate("def sum(a, b), do: a + b", 32))
    end)

  {:ok, final} = DeepSeekAPI.chat_completion(followup, tools, opts)
  true = String.contains?(final.content, "40")
  Task.await(embedding_task, 600_000)
  IO.puts("Tool-call/result round trip and overlapping CUDA embedding batches passed.")
  {memory, 0} = System.cmd("nvidia-smi", ["--query-gpu=memory.used,memory.free", "--format=csv"])
  IO.write(memory)
  {:ok, response} = Req.get("http://127.0.0.1:11434/api/ps")

  allocations =
    Enum.map(
      response.body["models"],
      &Map.take(&1, ["name", "size", "size_vram", "context_length"])
    )

  IO.inspect(allocations, label: "Ollama allocation")

  {:ok, _} =
    Req.post("http://127.0.0.1:11434/api/generate",
      json: %{model: opts[:model], keep_alive: 0},
      receive_timeout: 60_000
    )
end

IO.puts("Local verification complete; no remote model requests were made.")
