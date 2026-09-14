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

      assert log =~ "☏  [✓ deepseek_api"
      assert log =~ "%{model: \"deepseek-chat\"}"
    end

    test "captures error response and classifies failure" do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          result = ExternalCall.run(:test_service, [target: "api"], fn -> {:error, :timeout} end)
          assert result == {:error, :timeout}
        end)

      assert log =~ "☏  [✗ test_service timeout"
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
end
