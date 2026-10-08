defmodule Yoke.Brain.SessionStoreTest do
  use ExUnit.Case, async: true

  alias Yoke.Brain.SessionLmml
  alias Yoke.Brain.SessionStore

  setup do
    tmp_dir =
      Path.join(System.tmp_dir!(), "session_store_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf(tmp_dir) end)
    {:ok, tmp_dir: tmp_dir}
  end

  test "saves and loads session state to disk as an .lmml narrative", %{tmp_dir: tmp_dir} do
    session_state = %{
      session_id: "test_sess_1",
      model: "deepseek-chat",
      permission_mode: :ask_confirm,
      step_count: 5,
      total_prompt_tokens: 120,
      total_completion_tokens: 60,
      messages: [%{"role" => "user", "content" => "Hello"}],
      snapshots: [
        %{
          id: "cp_1",
          label: "Snap 1",
          timestamp: "2026-08-17T08:00:00Z",
          model: "deepseek-chat",
          messages: []
        }
      ]
    }

    assert {:ok, file_path} = SessionStore.save_session(session_state, tmp_dir)
    assert File.exists?(file_path)
    assert String.ends_with?(file_path, ".lmml")

    # The saved file is a valid lmml narrative (Markdown-superset).
    content = File.read!(file_path)
    assert String.contains?(content, "# Yoke Conversation: test_sess_1")
    assert String.contains?(content, "@@@manifest.json")
    assert String.contains?(content, "@@@message.0.json")

    assert {:ok, loaded} = SessionStore.load_session("test_sess_1", tmp_dir)
    assert loaded["session_id"] == "test_sess_1"
    assert loaded["model"] == "deepseek-chat"
    assert loaded["step_count"] == 5
    assert length(loaded["messages"]) == 1
    assert length(loaded["snapshots"]) == 1

    sessions = SessionStore.list_sessions(tmp_dir)
    assert "test_sess_1" in sessions
  end

  test "saves session with images as a .lmmlz zipped container and loads it back", %{
    tmp_dir: tmp_dir
  } do
    png_bytes = <<137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82>>

    session_state = %{
      session_id: "test_sess_zipped",
      model: "deepseek-v4-flash-vision-exp",
      permission_mode: :ask_confirm,
      step_count: 2,
      total_prompt_tokens: 50,
      total_completion_tokens: 25,
      messages: [
        %{"role" => "user", "content" => "Describe @screenshot.png"}
      ],
      snapshots: [],
      images: %{"screenshot.png" => png_bytes}
    }

    assert {:ok, file_path} = SessionStore.save_session(session_state, tmp_dir)
    assert File.exists?(file_path)
    assert String.ends_with?(file_path, ".lmmlz")

    # Ensures legacy .lmml file is not present when zipped
    refute File.exists?(Path.join(tmp_dir, ".yoke/sessions/test_sess_zipped.lmml"))

    assert {:ok, loaded} = SessionStore.load_session("test_sess_zipped", tmp_dir)
    assert loaded["session_id"] == "test_sess_zipped"
    assert loaded["images"]["screenshot.png"] == png_bytes

    sessions = SessionStore.list_sessions(tmp_dir)
    assert "test_sess_zipped" in sessions

    assert [meta] = SessionStore.list_session_metadata(tmp_dir)
    assert meta.session_id == "test_sess_zipped"

    # Delete session removes .lmmlz container
    assert {:ok, _} = SessionStore.delete_session("test_sess_zipped", tmp_dir)
    refute File.exists?(file_path)
  end

  test "round-trips structured messages losslessly through lmml", %{tmp_dir: tmp_dir} do
    messages = [
      %{"role" => "system", "content" => "You are an expert."},
      %{"role" => "user", "content" => "Run the tool"},
      %{
        "role" => "assistant",
        "content" => "",
        "tool_calls" => [
          %{
            "id" => "call_1",
            "type" => "function",
            "function" => %{"name" => "bash", "arguments" => "{\"command\":\"ls\"}"}
          }
        ]
      },
      %{"role" => "tool", "tool_call_id" => "call_1", "content" => "output"},
      %{"role" => "assistant", "content" => "Done!", "reasoning_content" => "thinking..."},
      %{
        "role" => "user",
        "content" => [
          %{"type" => "image_url", "image_url" => %{"url" => "data:image/png;base64,AAA"}},
          %{"type" => "text", "text" => "Describe this"}
        ]
      }
    ]

    session_state = %{
      session_id: "roundtrip",
      model: "deepseek-reasoner",
      permission_mode: :auto_approve,
      step_count: 3,
      total_prompt_tokens: 10,
      total_completion_tokens: 20,
      messages: messages,
      snapshots: []
    }

    {:ok, _} = SessionStore.save_session(session_state, tmp_dir)
    {:ok, loaded} = SessionStore.load_session("roundtrip", tmp_dir)
    assert loaded["messages"] == messages
    assert loaded["model"] == "deepseek-reasoner"
  end

  test "returns error when loading non-existent session", %{tmp_dir: tmp_dir} do
    assert {:error, msg} = SessionStore.load_session("non_existent", tmp_dir)
    assert msg =~ "does not exist"
  end

  test "falls back to loading a legacy .json session", %{tmp_dir: tmp_dir} do
    legacy = %{
      "session_id" => "legacy_json",
      "model" => "deepseek-chat",
      "permission_mode" => "ask_confirm",
      "step_count" => 2,
      "total_prompt_tokens" => 10,
      "total_completion_tokens" => 5,
      "messages" => [%{"role" => "user", "content" => "Hello"}],
      "snapshots" => []
    }

    File.mkdir_p!(Path.join(tmp_dir, ".yoke/sessions"))

    File.write!(
      Path.join(tmp_dir, ".yoke/sessions/legacy_json.json"),
      Jason.encode!(legacy)
    )

    assert {:ok, loaded} = SessionStore.load_session("legacy_json", tmp_dir)
    assert loaded["session_id"] == "legacy_json"
    assert length(loaded["messages"]) == 1

    # Legacy sessions are also discoverable via list_sessions / metadata.
    assert "legacy_json" in SessionStore.list_sessions(tmp_dir)
    assert [meta] = SessionStore.list_session_metadata(tmp_dir)
    assert meta.session_id == "legacy_json"
  end

  describe "import_session/3" do
    test "imports the native save_session schema and makes it resumable", %{tmp_dir: tmp_dir} do
      source_path = Path.join(tmp_dir, "external_export.json")

      File.write!(
        source_path,
        Jason.encode!(%{
          "session_id" => "from_source",
          "model" => "deepseek-reasoner",
          "permission_mode" => "auto_approve",
          "step_count" => 3,
          "total_prompt_tokens" => 100,
          "total_completion_tokens" => 50,
          "messages" => [%{"role" => "user", "content" => "Hello"}],
          "snapshots" => []
        })
      )

      assert {:ok, "from_source", file_path} =
               SessionStore.import_session(source_path, [], tmp_dir)

      assert File.exists?(file_path)
      assert String.ends_with?(file_path, ".lmml")

      assert {:ok, loaded} = SessionStore.load_session("from_source", tmp_dir)
      assert loaded["model"] == "deepseek-reasoner"
      assert length(loaded["messages"]) == 1
    end

    test "imports a bare {\"messages\": [...]} object, defaulting missing fields", %{
      tmp_dir: tmp_dir
    } do
      source_path = Path.join(tmp_dir, "bare_messages.json")

      File.write!(
        source_path,
        Jason.encode!(%{"messages" => [%{"role" => "user", "content" => "Hi"}]})
      )

      assert {:ok, session_id, _file_path} =
               SessionStore.import_session(source_path, [session_id: "bare_import"], tmp_dir)

      assert session_id == "bare_import"
      assert {:ok, loaded} = SessionStore.load_session("bare_import", tmp_dir)
      assert loaded["model"] == "deepseek-chat"
      assert length(loaded["messages"]) == 1
    end

    test "imports a raw top-level JSON array of messages", %{tmp_dir: tmp_dir} do
      source_path = Path.join(tmp_dir, "raw_array.json")

      File.write!(
        source_path,
        Jason.encode!([
          %{"role" => "user", "content" => "Hi"},
          %{"role" => "assistant", "content" => "Hello!"}
        ])
      )

      assert {:ok, session_id, _file_path} =
               SessionStore.import_session(source_path, [session_id: "raw_array_import"], tmp_dir)

      assert {:ok, loaded} = SessionStore.load_session(session_id, tmp_dir)
      assert length(loaded["messages"]) == 2
    end

    test "imports an .lmml narrative directly", %{tmp_dir: tmp_dir} do
      session_state = %{
        session_id: "lmml_source",
        model: "deepseek-chat",
        permission_mode: :ask_confirm,
        step_count: 1,
        total_prompt_tokens: 5,
        total_completion_tokens: 5,
        messages: [%{"role" => "user", "content" => "Imported from lmml"}],
        snapshots: []
      }

      {:ok, narrative} = SessionLmml.encode(session_state, "lmml_source")
      source_path = Path.join(tmp_dir, "conversation.lmml")
      File.write!(source_path, narrative)

      assert {:ok, "lmml_source", _file_path} =
               SessionStore.import_session(source_path, [], tmp_dir)

      assert {:ok, loaded} = SessionStore.load_session("lmml_source", tmp_dir)
      assert loaded["messages"] == [%{"role" => "user", "content" => "Imported from lmml"}]
    end

    test "imports a generic lmml narrative built with Lmml.Bundle", %{tmp_dir: tmp_dir} do
      narrative = """
      # Debugging session

      ## Turn 1 -- user

      Hello, can you help?

      @@@fix.diff
      - old
      + new
      @@@
      """

      source_path = Path.join(tmp_dir, "generic.lmml")
      File.write!(source_path, narrative)

      assert {:ok, session_id, _file_path} =
               SessionStore.import_session(source_path, [session_id: "generic_import"], tmp_dir)

      assert session_id == "generic_import"
      assert {:ok, loaded} = SessionStore.load_session("generic_import", tmp_dir)
      assert loaded["messages"] == []
    end

    test "refuses to overwrite an existing session unless overwrite: true", %{tmp_dir: tmp_dir} do
      source_path = Path.join(tmp_dir, "dup.json")

      File.write!(
        source_path,
        Jason.encode!(%{"messages" => [%{"role" => "user", "content" => "Hi"}]})
      )

      assert {:ok, "dup_id", _} =
               SessionStore.import_session(source_path, [session_id: "dup_id"], tmp_dir)

      assert {:error, msg} =
               SessionStore.import_session(source_path, [session_id: "dup_id"], tmp_dir)

      assert msg =~ "already exists"

      assert {:ok, "dup_id", _} =
               SessionStore.import_session(
                 source_path,
                 [session_id: "dup_id", overwrite: true],
                 tmp_dir
               )
    end

    test "returns an error for invalid JSON", %{tmp_dir: tmp_dir} do
      source_path = Path.join(tmp_dir, "invalid.json")
      File.write!(source_path, "{not valid json")

      assert {:error, msg} = SessionStore.import_session(source_path, [], tmp_dir)
      assert msg =~ "Invalid JSON"
    end

    test "returns an error when no messages array is present", %{tmp_dir: tmp_dir} do
      source_path = Path.join(tmp_dir, "no_messages.json")
      File.write!(source_path, Jason.encode!(%{"session_id" => "whatever"}))

      assert {:error, msg} = SessionStore.import_session(source_path, [], tmp_dir)
      assert msg =~ "messages"
    end

    test "returns an error when the source file does not exist", %{tmp_dir: tmp_dir} do
      assert {:error, msg} =
               SessionStore.import_session(Path.join(tmp_dir, "missing.json"), [], tmp_dir)

      assert msg =~ "Failed to read"
    end
  end

  test "extracts and truncates first user message title", %{tmp_dir: tmp_dir} do
    long_msg = String.duplicate("A long user prompt ", 10)

    session_state = %{
      session_id: "test_sess_title",
      model: "deepseek-chat",
      permission_mode: :auto_approve,
      step_count: 2,
      total_prompt_tokens: 10,
      total_completion_tokens: 10,
      messages: [
        %{"role" => "system", "content" => "System instructions..."},
        %{"role" => "user", "content" => long_msg}
      ],
      snapshots: []
    }

    {:ok, _} = SessionStore.save_session(session_state, tmp_dir)
    [meta] = SessionStore.list_session_metadata(tmp_dir)

    assert meta.session_id == "test_sess_title"
    assert String.ends_with?(meta.title, "...")
    assert String.length(meta.title) == 60
  end

  test "writes detailed .lmml_error.log report next to session file on LMML persistence failure",
       %{
         tmp_dir: tmp_dir
       } do
    session_state = %{
      session_id: "err_test_sess",
      model: "deepseek-chat",
      messages: [%{"role" => "user", "content" => "Crash test"}],
      snapshots: []
    }

    # Simulate an LMML encode failure by passing an invalid data shape or handling error
    dir = SessionStore.session_dir(tmp_dir)
    File.mkdir_p!(dir)

    primary_error = {:error, "Simulated Md.Parser match error"}

    # Call fallback_save directly
    assert {:ok, json_path} =
             SessionStore.fallback_save(session_state, dir, "err_test_sess", primary_error)

    assert File.exists?(json_path)

    log_path = Path.join(dir, "err_test_sess.lmml_error.log")
    assert File.exists?(log_path)

    log_content = File.read!(log_path)
    assert log_content =~ "Yoke LMML Persistence Error Report"
    assert log_content =~ "Simulated Md.Parser match error"
    assert log_content =~ "err_test_sess"
    assert log_content =~ "SUCCESS (JSON Fallback Saved)"
  end

  test "successfully saves and round-trips a session containing invalid UTF-8 bytes like byte 29",
       %{
         tmp_dir: tmp_dir
       } do
    session_state = %{
      session_id: "invalid_byte_session",
      model: "deepseek-chat",
      permission_mode: :ask_confirm,
      step_count: 1,
      total_prompt_tokens: 10,
      total_completion_tokens: 10,
      messages: [
        %{"role" => "user", "content" => <<"bad byte prompt ", 194, 29, " test">>},
        %{"role" => "assistant", "content" => "OK"},
        %{
          "role" => "tool",
          "tool_call_id" => "call_1",
          "content" => <<"tool result with byte ", 29>>
        }
      ],
      snapshots: []
    }

    assert {:ok, file_path} = SessionStore.save_session(session_state, tmp_dir)
    assert File.exists?(file_path)

    dir = SessionStore.session_dir(tmp_dir)
    log_path = Path.join(dir, "invalid_byte_session.lmml_error.log")
    refute File.exists?(log_path)

    assert {:ok, loaded} = SessionStore.load_session("invalid_byte_session", tmp_dir)
    assert length(loaded["messages"]) == 3
  end
end
