defmodule Yoke.ExternalCallTest do
  use ExUnit.Case, async: true

  alias Yoke.ExternalCall

  describe "run/4" do
    test "executes successful call and logs metrics" do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          Logger.configure(level: :debug)

          result =
            ExternalCall.run(:deepseek_api, [model: "deepseek-chat"], fn -> {:ok, "success"} end)

          assert result == {:ok, "success"}
        end)

      assert log =~ "⟡ API"
      assert log =~ "deepseek-chat"
      assert log =~ "success"
    end

    test "logs short summary of tool call response after duration" do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          Logger.configure(level: :debug)

          response = %{
            role: "assistant",
            content: "",
            tool_calls: [
              %{name: "read_file", arguments: %{"path" => "lib/foo.ex"}}
            ]
          }

          result =
            ExternalCall.run(:deepseek_api, [model: "deepseek-chat"], fn -> {:ok, response} end)

          assert result == {:ok, response}
        end)

      assert log =~ "⟡ API"
      assert log =~ "deepseek-chat"
      assert log =~ ~r/deepseek-chat \(\d+ms\) read_file\("lib\/foo\.ex"\)/
    end

    test "logs short summary of final markdown text response after duration" do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          Logger.configure(level: :debug)

          response = %{
            role: "assistant",
            content: "### Implementation Plan\n\n1. Modify external call module\n2. Run tests",
            tool_calls: []
          }

          result =
            ExternalCall.run(:deepseek_api, [model: "deepseek-chat"], fn -> {:ok, response} end)

          assert result == {:ok, response}
        end)

      assert log =~ "⟡ API"
      assert log =~ "deepseek-chat"
      assert log =~ "Implementation Plan Modify external call module Run tests"
    end

    test "captures error response and classifies failure" do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          result = ExternalCall.run(:test_service, [target: "api"], fn -> {:error, :timeout} end)
          assert result == {:error, :timeout}
        end)

      assert log =~ "⟡ API"
      assert log =~ "test_service failed (timeout"
    end
  end

  describe "classify_error/1" do
    test "classifies timeout errors" do
      assert ExternalCall.classify_error(:timeout) == :timeout
      assert ExternalCall.classify_error("Request timed out") == :timeout
    end

    test "classifies transport errors" do
      assert ExternalCall.classify_error(:econnrefused) == :transport
      assert ExternalCall.classify_error(:nxdomain) == :transport
      assert ExternalCall.classify_error("Host unreachable") == :transport
    end

    test "classifies general errors" do
      assert ExternalCall.classify_error("HTTP 400 Bad Request") == :error
      assert ExternalCall.classify_error(:invalid_json) == :error
    end
  end

  describe "summarize_response/1" do
    test "summarizes nil and empty payloads" do
      assert ExternalCall.summarize_response(nil) == ""
      assert ExternalCall.summarize_response("") == ""
      assert ExternalCall.summarize_response(%{}) == ""
    end

    test "summarizes single tool call with prominent argument" do
      resp = %{
        tool_calls: [
          %{name: "read_file", arguments: %{"path" => "lib/foo.ex"}}
        ]
      }

      assert ExternalCall.summarize_response(resp) == "read_file(\"lib/foo.ex\")"
    end

    test "summarizes tool call with json-encoded arguments" do
      resp = %{
        tool_calls: [
          %{"name" => "bash", "arguments" => ~s({"command": "mix test"})}
        ]
      }

      assert ExternalCall.summarize_response(resp) == "bash(\"mix test\")"
    end

    test "summarizes tool call without arguments" do
      resp = %{
        tool_calls: [%{name: "get_stats", arguments: %{}}]
      }

      assert ExternalCall.summarize_response(resp) == "get_stats()"
    end

    test "summarizes multiple tool calls" do
      resp = %{
        tool_calls: [
          %{name: "read_file", arguments: %{"path" => "lib/a.ex"}},
          %{name: "write_file", arguments: %{"path" => "lib/b.ex"}}
        ]
      }

      assert ExternalCall.summarize_response(resp) ==
               "read_file(\"lib/a.ex\"), write_file(\"lib/b.ex\")"

      resp3 = %{
        tool_calls: [
          %{name: "read_file", arguments: %{"path" => "lib/a.ex"}},
          %{name: "write_file", arguments: %{"path" => "lib/b.ex"}},
          %{name: "bash", arguments: %{"command" => "mix test"}}
        ]
      }

      assert ExternalCall.summarize_response(resp3) ==
               "read_file(\"lib/a.ex\"), write_file(\"lib/b.ex\") (+1)"
    end

    test "summarizes markdown text response stripping markdown markup" do
      resp = %{
        role: "assistant",
        content: "### Heading\n\n> Important note\n- Item 1\n- Item 2",
        tool_calls: []
      }

      assert ExternalCall.summarize_response(resp) == "Heading Important note Item 1 Item 2"
    end

    test "summarizes reasoning content when text content is empty" do
      resp = %{
        role: "assistant",
        content: "",
        reasoning_content: "Reflecting on the solution steps...",
        tool_calls: []
      }

      assert ExternalCall.summarize_response(resp) == "Reflecting on the solution steps..."
    end

    test "summarizes raw string payload" do
      assert ExternalCall.summarize_response("Simple string response") == "Simple string response"
    end

    test "unwraps choices array" do
      resp = %{
        choices: [
          %{message: %{content: "Completed successfully", tool_calls: []}}
        ]
      }

      assert ExternalCall.summarize_response(resp) == "Completed successfully"
    end
  end
end
