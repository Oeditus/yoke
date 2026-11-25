defmodule Yoke.Client.RequestDiagnosticsTest do
  use ExUnit.Case, async: true

  alias Yoke.Client.RequestDiagnostics

  describe "build/2" do
    test "measures the serialized payload, messages, and tools" do
      messages = [
        %{"role" => "system", "content" => "be brief"},
        %{"role" => "user", "content" => String.duplicate("a", 500)},
        %{"role" => "tool", "content" => String.duplicate("b", 2_000)}
      ]

      tools = [
        %{"type" => "function", "function" => %{"name" => "read_file", "description" => "Read"}}
      ]

      diag = RequestDiagnostics.build(%{"messages" => messages}, tools)

      assert diag.message_count == 3
      assert diag.tool_count == 1
      assert diag.payload_bytes > 0
      assert diag.tool_bytes > 0
      # The largest message is the 2000-byte tool result at index 2.
      assert diag.largest_message_role == "tool"
      assert diag.largest_message_index == 2
      assert diag.largest_message_bytes >= 2_000
      # The payload also carries the `"messages"` key and array brackets.
      assert diag.payload_bytes > diag.message_bytes
    end

    test "handles an empty request" do
      diag = RequestDiagnostics.build(%{"messages" => []}, [])

      assert diag.message_count == 0
      assert diag.tool_count == 0
      assert diag.largest_message_bytes == 0
      assert diag.largest_message_role == nil
      assert diag.largest_message_index == nil
    end

    test "reads atom-keyed messages" do
      diag = RequestDiagnostics.build(%{messages: [%{role: "user", content: "hi"}]}, [])

      assert diag.message_count == 1
      assert diag.largest_message_role == "user"
    end
  end

  describe "describe/1" do
    test "renders a content-free one-line summary" do
      messages = [
        %{"role" => "user", "content" => "SECRET_PROJECT_SOURCE"},
        %{"role" => "tool", "content" => String.duplicate("x", 4_000)}
      ]

      diag = RequestDiagnostics.build(%{"messages" => messages}, [])
      description = RequestDiagnostics.describe(diag)

      assert description =~ "payload"
      assert description =~ "2 messages"
      assert description =~ "largest"
      assert description =~ "role=tool #1"
      assert description =~ "tools 0 (0B)"
      # Content must never leak into diagnostics.
      refute description =~ "SECRET_PROJECT_SOURCE"
    end

    test "omits the largest-message fragment when there are no messages" do
      diag = RequestDiagnostics.build(%{"messages" => []}, [])
      description = RequestDiagnostics.describe(diag)

      assert description =~ "0 messages"
      refute description =~ "largest"
    end
  end

  describe "to_map/1" do
    test "returns plain values for structured logging" do
      diag = RequestDiagnostics.build(%{"messages" => [%{"role" => "user"}]}, [])
      map = RequestDiagnostics.to_map(diag)

      assert map.message_count == 1
      assert map.largest_message_role == "user"
      assert is_integer(map.payload_bytes)
    end
  end
end
