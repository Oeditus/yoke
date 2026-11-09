defmodule Yoke.InteractionCallSitesTest do
  @moduledoc """
  Proves that the seven blocking call sites enumerated in
  `docs/CI_PLAN.md` §2.1 actually route through `Yoke.Interaction`, rather
  than calling `Yoke.CLI.QuestionPrompt` directly.

  The seam is what makes headless CI possible: with
  `Yoke.Interaction.Policy` installed, none of these sites can block on a
  terminal. These tests install `Yoke.Test.StubInteraction` (which records
  every request in the caller's mailbox) and assert the request arrives with
  the right `kind`.
  """
  use ExUnit.Case, async: false
  @moduletag :tmp_dir

  alias Yoke.Brain.Session
  alias Yoke.Interaction

  setup do
    prior = Application.get_env(:yoke, :interaction)
    prior_god = Application.get_env(:yoke, :god_mode)
    Application.put_env(:yoke, :interaction, Yoke.Test.StubInteraction)
    # God mode short-circuits `QuestionPrompt` before it ever reaches a modal;
    # but more importantly the seam must be exercised for real, so make sure
    # nothing auto-answers behind our back.
    Application.put_env(:yoke, :god_mode, false)

    on_exit(fn ->
      if prior == nil,
        do: Application.delete_env(:yoke, :interaction),
        else: Application.put_env(:yoke, :interaction, prior)

      if prior_god == nil,
        do: Application.delete_env(:yoke, :god_mode),
        else: Application.put_env(:yoke, :god_mode, prior_god)
    end)

    :ok
  end

  describe "static call-site audit" do
    test "Yoke.Brain.Session no longer calls QuestionPrompt directly" do
      source = File.read!("lib/yoke/brain/session.ex")

      refute source =~ "QuestionPrompt.ask_single_question",
             "Brain.Session still asks the terminal directly; route it through Yoke.Interaction"

      refute source =~ "Yoke.CLI.Spinner.with_paused",
             "Brain.Session still pauses the spinner itself; Yoke.Interaction.TTY owns that"
    end

    test "Yoke.PRReview.CLI routes review confirmations through the seam" do
      source = File.read!("lib/yoke/pr_review/cli.ex")

      assert source =~ "Yoke.Interaction.ask(:review_fix",
             "review_yes?/3 must be a thin adapter over Yoke.Interaction"

      repl = File.read!("lib/yoke/cli/repl.ex")
      assert repl =~ "Yoke.PRReview.CLI.handle_review_fixes("
      assert repl =~ "Yoke.PRReview.CLI.maybe_record_review_patterns("
    end

    test "every kind the plan enumerates is raised somewhere in the session actor" do
      source = File.read!("lib/yoke/brain/session.ex")

      for kind <- [
            :plan_gate,
            :plan_revision,
            :loop_break,
            :api_error,
            :max_depth,
            :tool_permission
          ] do
        assert source =~ "Yoke.Interaction.ask(:#{kind}",
               "expected a Yoke.Interaction.ask(:#{kind}, ...) call site in Brain.Session"
      end
    end
  end

  describe "the seam answers headlessly" do
    test "a policy-backed ask never blocks and never asks" do
      prior = Application.get_env(:yoke, :interaction)
      Application.put_env(:yoke, :interaction, Yoke.Interaction.Policy)

      try do
        # No cwd has a policy file here, so every kind fails closed.
        for kind <- Interaction.kinds() do
          assert Interaction.ask(kind, %{cwd: "/nonexistent"}) == :deny
        end
      after
        Application.put_env(:yoke, :interaction, prior)
      end
    end

    test "the stub is consulted and its decision is honoured" do
      assert Interaction.ask(:plan_gate, %{answer: :approve}) == :approve
      assert_receive {:stub_interaction, :plan_gate, %{answer: :approve}}

      assert Interaction.ask(:loop_break, %{answer: {:answer, "amend"}}) == {:answer, "amend"}
      assert_receive {:stub_interaction, :loop_break, _}
    end
  end

  describe "Session.tool_permitted?/3 routes through the seam" do
    setup %{tmp_dir: dir} do
      # A session state shaped like the real one, without starting an actor.
      # `cwd` must be a scratch directory: the repo's own `.yoke/config.json`
      # allows `bash`, which would short-circuit the permission gate before it
      # ever reaches the seam.
      #
      # Point HOME at an empty directory too: `Yoke.Config.load_config/1`
      # merges `~/.yoke/config.json`, and a developer's personal config may
      # also allow `bash`. Both layers must be neutral for this test to
      # observe the seam rather than a pre-approved policy.
      # `Yoke.Config.load_config/1` merges `~/.yoke/config.json`, and a
      # developer's personal config routinely pre-approves `bash`. Rather than
      # mutate `HOME` (which `Path.expand("~")` caches process-wide), give the
      # session an explicit `session_tool_permissions` entry that is *not* an
      # allow, so the gate falls through to the confirmation branch. The
      # session-level policy wins over both config layers by design.

      workspace = Path.join(dir, "workspace")
      File.mkdir_p!(workspace)

      # `Yoke.Config.god_mode?/1` defaults to `true` under `MIX_ENV=test`
      # (so the interactive suite never blocks on a modal). That default would
      # auto-approve every confirmation before it reached the seam, so pin it
      # to `false` for the duration of these assertions.
      prior_god = Application.get_env(:yoke, :god_mode)
      Application.put_env(:yoke, :god_mode, false)

      on_exit(fn ->
        if prior_god == nil,
          do: Application.delete_env(:yoke, :god_mode),
          else: Application.put_env(:yoke, :god_mode, prior_god)
      end)

      state = %{
        cwd: workspace,
        session_tool_permissions: %{"bash" => "confirm"},
        sandbox_workspace: false,
        permission_mode: :ask_confirm,
        session_id: "interaction-test"
      }

      {:ok, state: state, workspace: workspace}
    end

    test "a confirmation-requiring tool asks the seam and honours a deny", %{
      state: state,
      workspace: workspace
    } do
      # `Yoke.Test.StubInteraction` defaults to `:deny` when the context has no
      # `:answer`, which is exactly the fail-closed answer a headless run wants.
      assert {:deny, reason, _state} =
               Session.tool_permitted?("bash", %{"command" => "echo hi"}, state)

      assert reason =~ "denied"
      assert_receive {:stub_interaction, :tool_permission, context}
      assert context.tool == "bash"
      assert context.cwd == workspace
    end

    test "a destructive shell command also asks the seam", %{state: state} do
      assert {:deny, reason, _state} =
               Session.tool_permitted?("bash", %{"command" => "rm -rf /"}, state)

      assert reason =~ "denied"
      assert_receive {:stub_interaction, :tool_permission, context}
      assert context.reason =~ "Destructive"
    end

    test "read-only tools never reach the seam", %{state: state} do
      assert {:allow, _} = Session.tool_permitted?("read_file", %{"path" => "mix.exs"}, state)
      refute_receive {:stub_interaction, :tool_permission, _}
    end
  end
end
