defmodule Yoke.Brain.MessageRepairTest do
  @moduledoc """
  A broken tool-call sequence makes the provider reject the *entire* request
  with HTTP 400, losing the conversation. These are the two recovery
  strategies, tested as pure list transforms.
  """
  use ExUnit.Case, async: true

  alias Yoke.Brain.MessageRepair

  defp assistant_with_calls(ids) do
    %{
      "role" => "assistant",
      "content" => "",
      "tool_calls" =>
        Enum.map(ids, fn id ->
          %{
            "id" => id,
            "type" => "function",
            "function" => %{"name" => "bash", "arguments" => "{}"}
          }
        end)
    }
  end

  defp tool_result(id, content) do
    %{"role" => "tool", "tool_call_id" => id, "content" => content}
  end

  describe "repair/1" do
    test "leaves a well-formed sequence untouched" do
      messages = [
        %{"role" => "user", "content" => "hi"},
        assistant_with_calls(["a"]),
        tool_result("a", "ok"),
        %{"role" => "assistant", "content" => "done"}
      ]

      assert MessageRepair.repair(messages) == messages
    end

    test "inserts a placeholder for an unanswered tool call" do
      messages = [
        %{"role" => "user", "content" => "hi"},
        assistant_with_calls(["a", "b"]),
        tool_result("a", "ok"),
        %{"role" => "assistant", "content" => "done"}
      ]

      repaired = MessageRepair.repair(messages)

      # Both calls are answered before the next assistant message.
      assert [_, _, %{"tool_call_id" => "a"}, %{"tool_call_id" => "b"}, %{"role" => "assistant"}] =
               repaired

      assert Enum.at(repaired, 3)["content"] =~ "result unavailable"
    end

    test "converts an orphaned tool message into a user message" do
      messages = [
        %{"role" => "user", "content" => "hi"},
        tool_result("ghost", "dangling")
      ]

      assert [_, converted] = MessageRepair.repair(messages)
      assert converted["role"] == "user"
      assert converted["content"] =~ "[Tool Output ghost]: dangling"
    end

    test "fills pending calls before a plain user message" do
      messages = [
        assistant_with_calls(["a"]),
        %{"role" => "user", "content" => "never mind"}
      ]

      repaired = MessageRepair.repair(messages)

      assert [_, %{"tool_call_id" => "a"}, %{"role" => "user"}] = repaired
    end

    test "is idempotent" do
      messages = [assistant_with_calls(["a"]), %{"role" => "assistant", "content" => "x"}]
      once = MessageRepair.repair(messages)

      assert MessageRepair.repair(once) == once
    end

    test "returns [] for non-list input" do
      assert MessageRepair.repair(nil) == []
      assert MessageRepair.repair(%{}) == []
    end
  end

  describe "flatten_tool_roles/1" do
    test "rewrites every tool message as a user message" do
      messages = [
        assistant_with_calls(["a"]),
        tool_result("a", "output")
      ]

      flattened = MessageRepair.flatten_tool_roles(messages)

      assert [assistant, tool_as_user] = flattened
      refute Map.has_key?(assistant, "tool_calls")
      assert tool_as_user["role"] == "user"
      assert tool_as_user["content"] =~ "[Tool Output a]: output"
    end

    test "leaves plain messages untouched" do
      messages = [%{"role" => "user", "content" => "hi"}]
      assert MessageRepair.flatten_tool_roles(messages) == messages
    end

    test "returns [] for non-list input" do
      assert MessageRepair.flatten_tool_roles(nil) == []
    end
  end
end
