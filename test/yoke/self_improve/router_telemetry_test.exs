defmodule Yoke.SelfImprove.RouterTelemetryTest do
  use ExUnit.Case, async: true

  alias Yoke.SelfImprove.{Router, Telemetry}

  setup do
    tmp = Path.join(System.tmp_dir!(), "yoke_router_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)
    {:ok, cwd: tmp}
  end

  test "telemetry records turns, marks undos, and computes bandit scores", %{cwd: cwd} do
    for _ <- 1..5 do
      {:ok, _} =
        Telemetry.record_turn(
          %{
            session_id: "s1",
            model: "deepseek-flash",
            phase: :codegen,
            language: "elixir",
            outcome: :success
          },
          cwd
        )
    end

    {:ok, _} =
      Telemetry.record_turn(
        %{
          session_id: "s1",
          model: "local",
          phase: :codegen,
          language: "elixir",
          outcome: :success
        },
        cwd
      )

    {:ok, undone} = Telemetry.mark_last_turn_undone("s1", cwd)
    assert undone["undone"] == true

    scores = Telemetry.bandit_scores(["deepseek-flash", "local"], cwd: cwd, phase: :codegen)
    assert hd(scores).model == "deepseek-flash"
    assert hd(scores).success_rate == 1.0
  end

  test "router classifies phases accurately" do
    assert Router.classify_phase("Fix the crashing ExUnit test") == :debug
    assert Router.classify_phase("Design the OTP supervision tree") == :design
    assert Router.classify_phase("Implement the new parser module") == :codegen
    assert Router.classify_phase("Where is SessionStore defined?") == :explore
  end

  test "router escalates on 2+ errors or loop hits and respects cooldown", %{cwd: cwd} do
    assert {:switch, "deepseek-reasoner", _} =
             Router.recommend(%{
               current_model: "deepseek-flash",
               turn_count: 5,
               last_auto_switch_turn: nil,
               consecutive_errors: 2,
               cwd: cwd
             })

    # Cooldown prevents immediate flip back on turn 6
    assert :keep ==
             Router.recommend(%{
               current_model: "deepseek-reasoner",
               turn_count: 6,
               last_auto_switch_turn: 5,
               phase: :explore,
               cwd: cwd
             })

    # Allowed after cooldown
    assert {:switch, "deepseek-flash", _} =
             Router.recommend(%{
               current_model: "deepseek-reasoner",
               turn_count: 8,
               last_auto_switch_turn: 5,
               phase: :explore,
               cwd: cwd
             })
  end
end
