defmodule Yoke.SelfImprove.MemoryCriticDecayTest do
  use ExUnit.Case, async: true

  alias Yoke.SelfImprove.{Critic, Decay, Episodes, Guardrails}

  setup do
    tmp = Path.join(System.tmp_dir!(), "yoke_mcd_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)
    {:ok, cwd: tmp}
  end

  test "episodes capture error->fix transitions, retrieve matches, and crystallize at 3 hits", %{
    cwd: cwd
  } do
    messages = [
      %{
        "role" => "tool",
        "name" => "bash",
        "content" => "CompileError: foo.ex:12: undefined function bar/1"
      },
      %{"role" => "tool", "name" => "replace_file", "content" => "Updated foo.ex to import Bar"}
    ]

    captured = Episodes.capture_from_messages(messages, cwd)
    assert length(captured) == 1

    # Hit 2 and 3 crystallize into Guardrails staging
    {:ok, _} =
      Episodes.record_episode(
        %{error: "CompileError: foo.ex:99: undefined function bar/1", fix: "import Bar"},
        cwd
      )

    {:ok, ep3} =
      Episodes.record_episode(
        %{error: "CompileError: foo.ex:45: undefined function bar/1", fix: "import Bar"},
        cwd
      )

    assert ep3["hits"] == 3

    staged = Guardrails.list_staged(cwd, "proposed")
    assert Enum.any?(staged, &(&1["kind"] == "practice"))

    preamble = Episodes.build_preamble("undefined function bar/1", cwd: cwd)
    assert preamble =~ "Relevant Past Error-Fix Episodes"
    assert preamble =~ "import Bar"
  end

  test "critic detects file thrashing without reading tests and emits async nudge" do
    summary = %{
      tool_calls: [%{name: "replace_file", error?: false}],
      edited_files: ["lib/foo.ex", "lib/foo.ex", "lib/foo.ex"],
      read_files: ["lib/foo.ex"],
      loop_hits: 0,
      bash_fallbacks: 1
    }

    res = Critic.evaluate(summary)
    assert res.score < 0.8
    assert res.nudge =~ "without reading its test file"

    {:ok, _pid} = Critic.assess_async(summary, session_pid: self())
    assert_receive {:critic_nudge, msg}, 500
    assert msg =~ "without reading its test file"
  end

  test "decay prunes single-hit episodes whose referenced files changed", %{cwd: cwd} do
    file = Path.join(cwd, "sample.ex")
    File.write!(file, "defmodule Sample, do: :v1\n")

    {:ok, _} =
      Episodes.record_episode(%{error: "Error in sample.ex", fix: "Fix v1", files: [file]}, cwd)

    assert length(Episodes.load(cwd)) == 1

    File.write!(file, "defmodule Sample, do: :v2\n")
    {:ok, %{kept: 0, pruned: 1}} = Decay.prune_stale_episodes(cwd)
    assert Episodes.load(cwd) == []
  end
end
