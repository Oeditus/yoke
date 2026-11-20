defmodule Yoke.ContextCompressorTest do
  use ExUnit.Case, async: true

  alias Yoke.Brain.ContextCompressor

  test "returns unchanged messages when history is empty or system-only" do
    messages = [%{"role" => "system", "content" => "You are an assistant"}]
    assert {:ok, ^messages, summary} = ContextCompressor.compress_messages(messages)
    assert String.contains?(summary, "No history to compress")
  end

  test "compresses conversation history into structured summary block" do
    messages = [
      %{"role" => "system", "content" => "System prompt"},
      %{"role" => "user", "content" => "Refactor session.ex"},
      %{"role" => "assistant", "content" => "Refactored session.ex successfully"}
    ]

    assert {:ok, new_messages, summary} =
             ContextCompressor.compress_messages(messages, mock: true)

    assert is_binary(summary)
    assert [_, _] = new_messages
    assert Enum.at(new_messages, 0)["role"] == "system"

    assert String.contains?(
             Enum.at(new_messages, 1)["content"],
             "Compressed Conversation Context"
           )
  end

  test "context_length_error?/1 detects DeepSeek and common provider context errors" do
    deepseek_err =
      ~s|Request rejected (HTTP 400): https://api.deepseek.com/chat/completions refused the request: %{"error" => %{"code" => "invalid_request_error", "message" => "This model's maximum context length is 1048576 tokens. However, you requested 1067233 tokens (1067233 in the messages, 0 in the completion). Please reduce the length of the messages or completion.", "type" => "invalid_request_error"}}|

    assert ContextCompressor.context_length_error?(deepseek_err)
    assert ContextCompressor.context_length_error?("error: context_length_exceeded")
    assert ContextCompressor.context_length_error?("prompt is too long: 210000 tokens > 200000")
    refute ContextCompressor.context_length_error?("Authentication failed (HTTP 401)")
    refute ContextCompressor.context_length_error?(nil)
  end

  test "target_tokens_from_error/3 scales target using reported limits" do
    messages = [
      %{"role" => "system", "content" => "sys"},
      %{"role" => "user", "content" => String.duplicate("abcd", 10_000)}
    ]

    err =
      "This model's maximum context length is 1048576 tokens. However, you requested 1067233 tokens"

    target0 = ContextCompressor.target_tokens_from_error(err, messages, attempt: 0)
    target1 = ContextCompressor.target_tokens_from_error(err, messages, attempt: 1)

    local_tokens = ContextCompressor.estimate_tokens(messages)
    assert target0 < local_tokens
    assert target1 < target0
  end

  test "compress_locally/2 summarizes older turns, keeps tool pairs intact, and fits budget" do
    messages = [
      %{"role" => "system", "content" => "System prompt"},
      %{"role" => "user", "content" => "Old question 1: " <> String.duplicate("a", 1200)},
      %{"role" => "assistant", "content" => "Old answer 1: " <> String.duplicate("b", 1200)},
      %{"role" => "user", "content" => "Old question 2: " <> String.duplicate("c", 1200)},
      %{
        "role" => "assistant",
        "content" => "",
        "tool_calls" => [
          %{
            "id" => "call_1",
            "type" => "function",
            "function" => %{"name" => "read_file", "arguments" => "{}"}
          }
        ]
      },
      %{
        "role" => "tool",
        "tool_call_id" => "call_1",
        "name" => "read_file",
        "content" => String.duplicate("x", 4000)
      },
      %{"role" => "user", "content" => "Latest question"},
      %{
        "role" => "assistant",
        "content" => "",
        "tool_calls" => [
          %{
            "id" => "call_2",
            "type" => "function",
            "function" => %{"name" => "run_command", "arguments" => "{}"}
          }
        ]
      },
      %{
        "role" => "tool",
        "tool_call_id" => "call_2",
        "name" => "run_command",
        "content" => String.duplicate("y", 4000)
      }
    ]

    before_tokens = ContextCompressor.estimate_tokens(messages)

    assert {:ok, compacted, summary} =
             ContextCompressor.compress_locally(messages, target_tokens: 900)

    assert summary =~ "Locally compacted context"
    assert ContextCompressor.estimate_tokens(compacted) <= 900
    assert ContextCompressor.estimate_tokens(compacted) < before_tokens
    assert hd(compacted) == %{"role" => "system", "content" => "System prompt"}

    # Latest user prompt is preserved and tool messages are never orphaned.
    assert Enum.any?(compacted, fn m ->
             m["role"] == "user" and m["content"] == "Latest question"
           end)

    tool_msgs = Enum.filter(compacted, &(&1["role"] == "tool"))

    for tm <- tool_msgs do
      call_id = tm["tool_call_id"]

      assert Enum.any?(compacted, fn m ->
               m["role"] == "assistant" and
                 Enum.any?(m["tool_calls"] || [], &(&1["id"] == call_id))
             end)
    end
  end

  test "skeletonize_elixir_ast/1 and truncate_smart/2 preserve module and function signatures" do
    elixir_src = """
    defmodule Demo.Worker do
      @moduledoc "Handles background jobs."
      alias Demo.Repo

      @spec run(String.t(), integer()) :: :ok
      def run(name, count) do
        Enum.each(1..count, fn i ->
          IO.puts("\#{name}: \#{i} " <> String.duplicate("x", 200))
        end)

        :ok
      end

      defp helper(x) do
        x + 1
      end
    end
    """

    assert {:ok, skeleton} = ContextCompressor.skeletonize_elixir_ast(elixir_src)
    assert skeleton =~ "defmodule Demo.Worker do"
    assert skeleton =~ "alias Demo.Repo"
    assert skeleton =~ "@spec run(String.t(), integer()) :: :ok"
    assert skeleton =~ "def run(name, count) # [body omitted"
    assert skeleton =~ "defp helper(x) # [body omitted"
    refute skeleton =~ "String.duplicate"

    compacted = ContextCompressor.truncate_smart(elixir_src, 350)
    assert compacted =~ "defmodule Demo.Worker do"
    assert String.length(compacted) <= 350
  end

  test "compress_locally/2 deduplicates superseded file reads" do
    messages = [
      %{"role" => "system", "content" => "System"},
      %{"role" => "user", "content" => "Read foo.ex"},
      %{
        "role" => "assistant",
        "content" => "",
        "tool_calls" => [
          %{
            "id" => "read_1",
            "type" => "function",
            "function" => %{"name" => "read_file", "arguments" => ~s({"path":"lib/foo.ex"})}
          }
        ]
      },
      %{
        "role" => "tool",
        "tool_call_id" => "read_1",
        "name" => "read_file",
        "content" => String.duplicate("old-content ", 200)
      },
      %{"role" => "user", "content" => "Read foo.ex again"},
      %{
        "role" => "assistant",
        "content" => "",
        "tool_calls" => [
          %{
            "id" => "read_2",
            "type" => "function",
            "function" => %{"name" => "read_file", "arguments" => ~s({"path":"lib/foo.ex"})}
          }
        ]
      },
      %{
        "role" => "tool",
        "tool_call_id" => "read_2",
        "name" => "read_file",
        "content" => "new-content"
      }
    ]

    assert {:ok, compacted, _summary} =
             ContextCompressor.compress_locally(messages, target_tokens: 2000)

    assert Enum.any?(compacted, fn m ->
             m["tool_call_id"] == "read_1" and String.contains?(m["content"], "Superseded")
           end)

    assert Enum.any?(compacted, fn m ->
             m["tool_call_id"] == "read_2" and m["content"] == "new-content"
           end)
  end

  test "build_compacted_snapshot/2 returns snapshot metadata and compacted messages" do
    messages = [
      %{"role" => "system", "content" => "System"},
      %{"role" => "user", "content" => "First turn"},
      %{"role" => "assistant", "content" => "First reply"}
    ]

    snapshot = ContextCompressor.build_compacted_snapshot(messages)
    assert is_map(snapshot)
    assert is_list(snapshot["messages"])
    assert is_binary(snapshot["summary"])
    assert is_integer(snapshot["estimated_tokens"])
    assert snapshot["source_message_count"] == 3
    assert is_binary(snapshot["updated_at"])
  end
end
