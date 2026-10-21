defmodule Yoke.Brain.SessionLmmlTest do
  use ExUnit.Case, async: true

  alias Yoke.Brain.SessionLmml

  describe "encode/2" do
    test "produces a valid lmml narrative with manifest and message embeds" do
      session_state = %{
        session_id: "abc",
        model: "deepseek-chat",
        permission_mode: :ask_confirm,
        step_count: 2,
        total_prompt_tokens: 10,
        total_completion_tokens: 20,
        messages: [
          %{"role" => "system", "content" => "sys"},
          %{"role" => "user", "content" => "hi"}
        ],
        snapshots: []
      }

      assert {:ok, narrative} = SessionLmml.encode(session_state, "abc")
      assert String.contains?(narrative, "# Yoke Conversation: abc")
      assert String.contains?(narrative, "@@@manifest.json")
      assert String.contains?(narrative, "@@@message.0.json")
      assert String.contains?(narrative, "@@@message.1.json")
      assert String.contains?(narrative, "## USER")
      assert String.contains?(narrative, "## SYSTEM")
      assert String.contains?(narrative, "hi")
    end

    test "renders a human-readable view of multimodal and tool-call messages" do
      session_state = %{
        session_id: "x",
        model: "deepseek-chat",
        permission_mode: :ask_confirm,
        step_count: 0,
        total_prompt_tokens: 0,
        total_completion_tokens: 0,
        messages: [
          %{
            "role" => "user",
            "content" => [
              %{"type" => "image_url", "image_url" => %{"url" => "data:image/png;base64,AAA"}},
              %{"type" => "text", "text" => "What is this?"}
            ]
          },
          %{
            "role" => "assistant",
            "content" => "",
            "tool_calls" => [
              %{"id" => "c1", "type" => "function", "function" => %{"name" => "bash"}}
            ]
          }
        ],
        snapshots: []
      }

      assert {:ok, narrative} = SessionLmml.encode(session_state, "x")
      assert String.contains?(narrative, "[Image: data:image/png;base64,AAA]")
      assert String.contains?(narrative, "What is this?")
      assert String.contains?(narrative, "tool calls: bash")
    end

    test "escapes literal @@@ in message content so it cannot truncate the embed" do
      # A tool result that read a nested .lmml file (or a session export) embeds
      # its own @@@manifest.json / @@@message.N.json markers as literal content.
      # Un-escaped, that @@@ would terminate the enclosing embed block early and
      # corrupt the narrative (see the SessionLmml.escape_json/1 doc).
      nested_lmml =
        ~s|# nested\n\n@@@manifest.json\n{"session_id":"inner"}\n@@@\n\n| <>
          ~s|@@@message.0.json\n{"role":"user","content":"hi"}\n@@@\n|

      session_state = %{
        session_id: "esc",
        model: "deepseek-chat",
        permission_mode: :ask_confirm,
        step_count: 1,
        total_prompt_tokens: 0,
        total_completion_tokens: 0,
        messages: [
          %{"role" => "user", "content" => "read the lmml file"},
          %{"role" => "tool", "tool_call_id" => "c1", "content" => nested_lmml}
        ],
        snapshots: []
      }

      assert {:ok, narrative} = SessionLmml.encode(session_state, "esc")

      # The message JSON embed must not contain a bare @@@ that would close it
      # early; the literal markers must be JSON-escaped as \u0040\u0040\u0040.
      assert String.contains?(narrative, "\\u0040\\u0040\\u0040")

      # And the narrative must round-trip losslessly, restoring the literal @@@.
      assert {:ok, decoded} = SessionLmml.decode(narrative)

      tool_msg = Enum.find(decoded["messages"], &(&1["role"] == "tool"))
      assert tool_msg["content"] == nested_lmml
    end

    test "escapes literal @@@ inside snapshot messages in the manifest" do
      # Snapshots carry full message history, including tool results that may
      # contain literal @@@ (e.g. a prior read of a .lmml file). Those live in
      # the @@manifest.json embed, which must also be protected.
      nested = "result with @@@marker and @@@manifest.json inside"

      session_state = %{
        session_id: "snap",
        model: "deepseek-chat",
        permission_mode: :ask_confirm,
        step_count: 1,
        total_prompt_tokens: 0,
        total_completion_tokens: 0,
        messages: [%{"role" => "user", "content" => "hi"}],
        snapshots: [
          %{
            id: "s1",
            label: "L1",
            timestamp: nil,
            model: "m",
            messages: [%{"role" => "tool", "tool_call_id" => "c", "content" => nested}]
          }
        ]
      }

      assert {:ok, narrative} = SessionLmml.encode(session_state, "snap")
      assert String.contains?(narrative, "\\u0040\\u0040\\u0040")
      assert {:ok, _decoded} = SessionLmml.decode(narrative)
    end
  end

  describe "decode/1" do
    test "round-trips a session_state losslessly" do
      messages = [
        %{"role" => "system", "content" => "You are an expert."},
        %{"role" => "user", "content" => "Hello"},
        %{"role" => "assistant", "content" => "Hi!", "reasoning_content" => "thinking"},
        %{
          "role" => "assistant",
          "content" => "",
          "tool_calls" => [
            %{
              "id" => "c1",
              "type" => "function",
              "function" => %{"name" => "bash", "arguments" => "{}"}
            }
          ]
        },
        %{"role" => "tool", "tool_call_id" => "c1", "content" => "out"}
      ]

      session_state = %{
        session_id: "roundtrip",
        model: "deepseek-reasoner",
        permission_mode: :auto_approve,
        step_count: 4,
        total_prompt_tokens: 100,
        total_completion_tokens: 50,
        messages: messages,
        snapshots: [
          %{
            id: "cp_1",
            label: "Checkpoint",
            timestamp: "2026-08-17T08:00:00Z",
            model: "deepseek-chat",
            messages: [%{"role" => "user", "content" => "earlier"}]
          }
        ]
      }

      {:ok, narrative} = SessionLmml.encode(session_state, "roundtrip")
      assert {:ok, decoded} = SessionLmml.decode(narrative)

      assert decoded["messages"] == messages
      assert decoded["session_id"] == "roundtrip"
      assert decoded["model"] == "deepseek-reasoner"
      assert decoded["permission_mode"] == "auto_approve"
      assert decoded["step_count"] == 4
      assert decoded["total_prompt_tokens"] == 100
      assert decoded["total_completion_tokens"] == 50
      assert [snap] = decoded["snapshots"]
      assert snap["label"] == "Checkpoint"
      assert snap["messages"] == [%{"role" => "user", "content" => "earlier"}]
    end

    test "defaults missing manifest fields" do
      narrative = """
      # Yoke Conversation: minimal

      @@@manifest.json
      {}
      @@@

      ## USER

      @@@message.0.json
      {"role":"user","content":"hi"}
      @@@
      """

      assert {:ok, decoded} = SessionLmml.decode(narrative)
      assert decoded["messages"] == [%{"role" => "user", "content" => "hi"}]
      assert decoded["model"] == "deepseek-flash"
      assert decoded["permission_mode"] == "ask_confirm"
      assert decoded["step_count"] == 0
      assert decoded["snapshots"] == []
    end

    test "rejects an invalid message embed" do
      narrative = """
      # Yoke Conversation: bad

      @@@manifest.json
      {}
      @@@

      ## USER

      @@@message.0.json
      not valid json
      @@@
      """

      assert {:error, _reason} = SessionLmml.decode(narrative)
    end

    test "decodes from a Lmml.Bundle directly" do
      {:ok, narrative} =
        SessionLmml.encode(
          %{
            session_id: "bundle",
            model: "deepseek-chat",
            permission_mode: :ask_confirm,
            step_count: 0,
            total_prompt_tokens: 0,
            total_completion_tokens: 0,
            messages: [%{"role" => "user", "content" => "from bundle"}],
            snapshots: []
          },
          "bundle"
        )

      {:ok, bundle} = Lmml.Bundle.new_text("bundle.lmml", narrative)
      assert {:ok, decoded} = SessionLmml.decode(bundle)
      assert decoded["messages"] == [%{"role" => "user", "content" => "from bundle"}]
    end
  end

  describe "validate/1" do
    test "validates valid session narrative" do
      session_state = %{
        session_id: "val",
        messages: [%{"role" => "user", "content" => "test"}]
      }

      {:ok, narrative} = SessionLmml.encode(session_state, "val")
      assert :ok = SessionLmml.validate(narrative)
    end
  end

  describe "to_markdown/1" do
    test "converts session narrative to clean markdown" do
      session_state = %{
        session_id: "md_test",
        messages: [%{"role" => "user", "content" => "hello world"}]
      }

      {:ok, narrative} = SessionLmml.encode(session_state, "md_test")
      assert {:ok, md} = SessionLmml.to_markdown(narrative)
      assert String.contains?(md, "hello world")
    end
  end
end
