defmodule YokeTest do
  use ExUnit.Case
  # `Yoke.start_session/1` needs `Yoke.Brain.SessionSupervisor`.
  # See `test/test_helper.exs`.
  @moduletag :app

  test "starts a session via top-level API and sends message" do
    session_pid =
      case Yoke.start_session(session_id: "api_test") do
        {:ok, session_pid} -> session_pid
        {:error, {:already_started, session_pid}} -> session_pid
      end

    assert is_pid(session_pid)

    {:ok, response} = Yoke.send_message(session_pid, "What tools do you have?")
    assert is_binary(response.content)
  end

  test "returns non-empty version string matching configured version" do
    vsn = Yoke.version()
    assert is_binary(vsn)
    assert vsn =~ ~r/^\d+\.\d+\.\d+/
    assert vsn == Mix.Project.config()[:version]
  end
end
