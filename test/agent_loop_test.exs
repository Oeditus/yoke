defmodule Yoke.Brain.AgentLoopTest do
  use ExUnit.Case, async: true

  alias Yoke.Brain.AgentLoop

  describe "AgentLoop duplicate tool call detection" do
    test "returns true when identical tool calls with identical arguments repeat" do
      messages = [
        %{"role" => "user", "content" => "List files"},
        %{
          "role" => "assistant",
          "content" => "",
          "tool_calls" => [
            %{
              "id" => "call_1",
              "function" => %{"name" => "list_dir", "arguments" => "{\"path\":\".\"}"}
            }
          ]
        },
        %{"role" => "tool", "content" => "file1.txt\nfile2.txt"}
      ]

      new_tool_calls = [%{id: "call_2", name: "list_dir", arguments: %{"path" => "."}}]

      assert AgentLoop.duplicate_tool_calls?(messages, new_tool_calls) == true
    end

    test "returns false when tool calls or arguments differ" do
      messages = [
        %{"role" => "user", "content" => "List files"},
        %{
          "role" => "assistant",
          "content" => "",
          "tool_calls" => [
            %{
              "id" => "call_1",
              "function" => %{"name" => "list_dir", "arguments" => "{\"path\":\".\"}"}
            }
          ]
        }
      ]

      new_tool_calls = [%{id: "call_2", name: "list_dir", arguments: %{"path" => "lib"}}]

      assert AgentLoop.duplicate_tool_calls?(messages, new_tool_calls) == false
    end

    test "does not deduplicate repeatable tools like bash probes across turns" do
      messages = [
        %{"role" => "user", "content" => "Check status"},
        %{
          "role" => "assistant",
          "content" => "",
          "tool_calls" => [
            %{
              "id" => "call_1",
              "function" => %{
                "name" => "bash",
                "arguments" => "{\"command\":\"curl -s http://localhost:4000/health\"}"
              }
            }
          ]
        },
        %{"role" => "tool", "content" => "status: starting"}
      ]

      new_tool_calls = [
        %{
          id: "call_2",
          name: "bash",
          arguments: %{"command" => "curl -s http://localhost:4000/health"}
        }
      ]

      # Probes must be permitted to repeat to observe changing external state
      assert AgentLoop.duplicate_tool_calls?(messages, new_tool_calls) == false
    end
  end

  describe "AgentLoop circuit breaker for non-standard tool failures" do
    test "disables non-standard tool after 3 consecutive failures" do
      state = %{
        tools: [%{name: "mcp_custom_tool"}, %{name: "read_file"}],
        tool_failure_counts: %{},
        messages: []
      }

      {state1, nil} = AgentLoop.handle_tool_failure("mcp_custom_tool", {:error, "failed"}, state)
      assert state1.tool_failure_counts["mcp_custom_tool"] == 1
      assert length(state1.tools) == 2

      {state2, nil} =
        AgentLoop.handle_tool_failure("mcp_custom_tool", {:error, "failed"}, state1)

      assert state2.tool_failure_counts["mcp_custom_tool"] == 2

      {state3, notice} =
        AgentLoop.handle_tool_failure("mcp_custom_tool", {:error, "failed"}, state2)

      assert state3.tool_failure_counts["mcp_custom_tool"] == 3
      assert length(state3.tools) == 1
      assert notice["content"] =~ "Fallback mode activated"
    end

    test "does not count standard tools for failure circuit breaker" do
      state = %{
        tools: [%{name: "read_file"}],
        tool_failure_counts: %{},
        messages: []
      }

      {state1, nil} = AgentLoop.handle_tool_failure("read_file", {:error, "failed"}, state)
      assert state1.tool_failure_counts == %{}
    end
  end
end
