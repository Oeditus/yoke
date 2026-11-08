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
end
