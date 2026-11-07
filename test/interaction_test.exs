defmodule Yoke.InteractionTest do
  # Not async: these assertions swap the global `:yoke, :interaction` and
  # `:yoke, :output_mode` application env, which every other test reads.
  use ExUnit.Case, async: false
  @moduletag :tmp_dir

  alias Yoke.Interaction
  alias Yoke.Interaction.Policy
  alias Yoke.Interaction.TTY

  describe "the behaviour contract" do
    test "declares every kind the agent loop can raise" do
      kinds = Interaction.kinds()

      assert :plan_gate in kinds
      assert :plan_revision in kinds
      assert :loop_break in kinds
      assert :api_error in kinds
      assert :max_depth in kinds
      assert :tool_permission in kinds
      assert :review_fix in kinds
    end

    test "both bundled implementations declare the behaviour" do
      assert TTY.__info__(:attributes)[:behaviour] == [Yoke.Interaction]
      assert Policy.__info__(:attributes)[:behaviour] == [Yoke.Interaction]
    end

    test "impl/0 defaults to the interactive TTY implementation" do
      prior = Application.get_env(:yoke, :interaction)
      Application.delete_env(:yoke, :interaction)

      try do
        assert Interaction.impl() == Yoke.Interaction.TTY
      after
        if prior, do: Application.put_env(:yoke, :interaction, prior)
      end
    end

    test "ask/2 dispatches to the configured implementation" do
      prior = Application.get_env(:yoke, :interaction)
      Application.put_env(:yoke, :interaction, Yoke.Test.StubInteraction)

      try do
        assert Interaction.ask(:plan_gate, %{answer: :approve}) == :approve
        assert Interaction.ask(:loop_break, %{answer: :deny}) == :deny
      after
        if prior,
          do: Application.put_env(:yoke, :interaction, prior),
          else: Application.delete_env(:yoke, :interaction)
      end
    end
  end

  describe "Yoke.Interaction.TTY classification" do
    test "maps plan-gate selections onto approve / revise / deny" do
      assert TTY.classify_plan_selection("Approve & execute") == :approve
      assert TTY.classify_plan_selection("Request changes") == {:answer, "Request changes"}
      assert TTY.classify_plan_selection("Deny") == :deny
      assert TTY.classify_plan_selection("something else") == :deny
    end

    test "classifies tool-permission selections with their persistence level" do
      assert TTY.classify_tool_permission("Allow once") == {:allow, :once}
      assert TTY.classify_tool_permission("Allow always for this session") == {:allow, :session}

      assert TTY.classify_tool_permission("Allow always (save to project config)") ==
               {:allow, :project}

      assert TTY.classify_tool_permission("Allow always (save to global config)") ==
               {:allow, :global}

      assert TTY.classify_tool_permission("Deny tool execution") == {:deny, :once}

      assert TTY.classify_tool_permission("Deny always (save to project config)") ==
               {:deny, :project}

      assert TTY.classify_tool_permission("Deny always (save to global config)") ==
               {:deny, :global}
    end

    test "classifies continue / retry / loop / yes-no selections" do
      assert TTY.classify_continue_or_stop("Continue execution (100 more iterations)") == :approve
      assert TTY.classify_continue_or_stop("Stop turn here") == :deny

      assert TTY.classify_retry_or_stop("Retry API call") == :approve
      assert TTY.classify_retry_or_stop("Stop turn here") == :deny

      assert TTY.classify_loop_choice("Force model to summarize without tools") == :approve
      assert TTY.classify_loop_choice("Stop turn here (break loop)") == :deny

      assert TTY.classify_yes_no("Yes, update living review patterns") == :approve
      assert TTY.classify_yes_no("No, skip pattern update (Recommended)") == :deny
    end

    test "an unknown kind fails closed" do
      assert TTY.ask(:totally_unknown, %{}) == :deny
    end
  end

  describe "Yoke.Interaction.Policy" do
    test "every interaction kind has a policy default" do
      # A kind missing from `defaults/0` can never be set to "approve" via a
      # policy file -- it silently falls back to the `Map.get(..., "deny")`
      # branch. This invariants catches a new kind being added to the
      # behaviour without a matching policy key.
      defaults = Policy.defaults() |> Map.keys() |> MapSet.new()
      kinds = Interaction.kinds() |> Enum.map(&Atom.to_string/1) |> MapSet.new()

      missing = MapSet.difference(kinds, defaults)

      assert MapSet.size(missing) == 0,
             "interaction kinds missing from Policy.defaults/0: #{inspect(MapSet.to_list(missing))}"
    end

    test "every kind can be approved via a policy file", %{tmp_dir: dir} do
      for kind <- Interaction.kinds() do
        Policy.write(dir, %{Atom.to_string(kind) => "approve"})
        assert Policy.ask(kind, %{cwd: dir}) == :approve, "#{kind} could not be approved"
      end
    end

    setup do
      prior = System.get_env("YOKE_POLICY")
      System.delete_env("YOKE_POLICY")

      on_exit(fn ->
        # Always clear first, then restore only if there was something to
        # restore. Leaving `YOKE_POLICY` set would leak an approve-everything
        # policy into every later test in the VM.
        System.delete_env("YOKE_POLICY")
        if prior, do: System.put_env("YOKE_POLICY", prior)
      end)

      :ok
    end

    test "defaults are fail-closed and read-only" do
      policy = Policy.defaults()

      assert policy["plan_gate"] == "deny"
      assert policy["loop_break"] == "deny"
      assert policy["api_error"] == "deny"
      assert policy["max_depth"] == "deny"
      assert policy["tool_permission"] == "deny"
      assert policy["review_fix"] == "deny"
      assert policy["allow_writes"] == false
      assert policy["fail_on"] == "high"
    end

    test "never blocks: every kind answers immediately with the default deny", %{tmp_dir: dir} do
      for kind <- Interaction.kinds() do
        assert Policy.ask(kind, %{cwd: dir}) == :deny
      end
    end

    test "a policy file can approve individual kinds", %{tmp_dir: dir} do
      {:ok, path} = Policy.write(dir, %{"plan_gate" => "approve"})
      assert File.regular?(path)

      assert Policy.ask(:plan_gate, %{cwd: dir}) == :approve
      assert Policy.ask(:loop_break, %{cwd: dir}) == :deny
    end

    test "load/1 merges over defaults and never loses keys", %{tmp_dir: dir} do
      Policy.write(dir, %{"fail_on" => "medium", "max_tool_calls" => 7})
      policy = Policy.load(dir)

      assert policy["fail_on"] == "medium"
      assert policy["max_tool_calls"] == 7
      assert policy["loop_break"] == "deny"
      assert policy["max_cost_usd"] == 2.0
    end

    test "malformed values are dropped in favour of the safe default", %{tmp_dir: dir} do
      Policy.write(dir, %{
        "plan_gate" => "maybe",
        "fail_on" => "catastrophic",
        "max_tool_calls" => -5,
        "max_cost_usd" => "cheap",
        "allow_writes" => "yes"
      })

      policy = Policy.load(dir)

      assert policy["plan_gate"] == "deny"
      assert policy["fail_on"] == "high"
      assert policy["max_tool_calls"] == 120
      assert policy["max_cost_usd"] == 2.0
      assert policy["allow_writes"] == false
    end

    test "a malformed JSON file fails closed instead of raising", %{tmp_dir: dir} do
      File.mkdir_p!(Path.join(dir, ".yoke"))
      File.write!(Path.join(dir, ".yoke/policy.json"), "{not json")

      assert Policy.load(dir) == Policy.defaults()
      assert Policy.ask(:plan_gate, %{cwd: dir}) == :deny
    end

    test "a missing file fails closed", %{tmp_dir: dir} do
      assert Policy.load(dir) == Policy.defaults()
    end

    test "YOKE_POLICY takes precedence over the repo file", %{tmp_dir: dir} do
      Policy.write(dir, %{"plan_gate" => "deny"})

      other = Path.join(dir, "override.json")
      File.write!(other, Yoke.Json.encode!(%{"plan_gate" => "approve"}))

      prior = System.get_env("YOKE_POLICY")
      System.put_env("YOKE_POLICY", other)

      on_exit(fn ->
        if prior == nil,
          do: System.delete_env("YOKE_POLICY"),
          else: System.put_env("YOKE_POLICY", prior)
      end)

      assert Policy.ask(:plan_gate, %{cwd: dir}) == :approve
    end

    test "an explicit :policy in the context wins over disk", %{tmp_dir: dir} do
      Policy.write(dir, %{"plan_gate" => "deny"})

      assert Policy.ask(:plan_gate, %{cwd: dir, policy: %{"plan_gate" => "approve"}}) == :approve
    end

    test "budget accessors read the effective policy", %{tmp_dir: dir} do
      Policy.write(dir, %{
        "allow_writes" => true,
        "fail_on" => "low",
        "max_tool_calls" => 42,
        "max_wall_clock_s" => 60,
        "max_cost_usd" => 0.5,
        "max_tokens" => 1000
      })

      assert Policy.allow_writes?(dir)
      assert Policy.fail_on(dir) == "low"
      assert Policy.max_tool_calls(dir) == 42
      assert Policy.max_wall_clock_s(dir) == 60
      assert Policy.max_cost_usd(dir) == 0.5
      assert Policy.max_tokens(dir) == 1000
    end

    test "never consults the user's home directory", %{tmp_dir: dir} do
      # A policy file in the working directory is the only file consulted.
      # Prove it by pointing HOME at a directory that contains a policy
      # which would approve everything, and confirming it is ignored.
      home = Path.join(dir, "fake-home")
      File.mkdir_p!(Path.join(home, ".yoke"))
      File.write!(Path.join(home, ".yoke/policy.json"), ~s({"plan_gate": "approve"}))

      prior_home = System.get_env("HOME")
      System.put_env("HOME", home)

      try do
        workspace = Path.join(dir, "workspace")
        File.mkdir_p!(workspace)

        assert Policy.load(workspace) == Policy.defaults()
        assert Policy.ask(:plan_gate, %{cwd: workspace}) == :deny
      after
        if prior_home, do: System.put_env("HOME", prior_home)
      end
    end
  end
end
