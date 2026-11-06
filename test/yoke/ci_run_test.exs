defmodule Yoke.CI.RunTest do
  use ExUnit.Case, async: false
  @moduletag :tmp_dir

  alias Yoke.CI.Run

  describe "list/1" do
    test "returns workflow definitions with name, description and source", %{tmp_dir: dir} do
      assert {:ok, definitions} = Run.list(dir)
      assert is_list(definitions)

      # The bundled `elixir` workflow ships with yoke, so it is always present.
      assert Enum.any?(definitions, fn d -> d.name == "elixir" end)
      assert Enum.all?(definitions, &Map.has_key?(&1, :name))
    end

    test "never raises for an unreadable directory" do
      assert {:ok, _} = Run.list("/nonexistent/path/for/yoke/run/test")
    end
  end

  describe "install_seams/1" do
    setup do
      keys = [:interaction, :auto_start_ragex, :non_interactive, :output_mode]
      prior = Map.new(keys, fn key -> {key, Application.get_env(:yoke, key)} end)

      on_exit(fn ->
        Enum.each(prior, fn
          {key, nil} -> Application.delete_env(:yoke, key)
          {key, value} -> Application.put_env(:yoke, key, value)
        end)
      end)

      :ok
    end

    test "installs the policy interaction so no step can block", %{tmp_dir: dir} do
      assert :ok = Run.install_seams(dir)
      assert Application.get_env(:yoke, :interaction) == Yoke.Interaction.Policy
      assert Application.get_env(:yoke, :auto_start_ragex) == false
    end
  end

  describe "run/2" do
    test "an unknown workflow is an error, not a crash", %{tmp_dir: dir} do
      assert {:error, reason} = Run.run("no-such-workflow", cwd: dir, seed_prompt: "x")
      assert is_binary(reason)
    end

    test "an exhausted budget aborts before the workflow starts", %{tmp_dir: dir} do
      Yoke.Interaction.Policy.write(dir, %{"max_tool_calls" => 0})

      # A zero tool-call budget is already exhausted (0 >= 0).
      assert {:error, reason} = Run.run("elixir", cwd: dir, seed_prompt: "x")
      assert reason =~ "budget"
    end
  end

  describe "workflow steps route through the interaction seam" do
    test "task_split no longer calls QuestionPrompt directly" do
      source = File.read!("lib/yoke/workflow/steps/task_split.ex")

      refute source =~ "QuestionPrompt.ask_single_question",
             "task_split must route its split confirmation through Yoke.Interaction"

      assert source =~ "Yoke.Interaction.ask(:workflow_confirm"
    end

    test "branch no longer calls QuestionPrompt directly" do
      source = File.read!("lib/yoke/workflow/steps/branch.ex")

      refute source =~ "QuestionPrompt.ask_single_question",
             "branch must route its base-branch confirmation through Yoke.Interaction"

      assert source =~ "Yoke.Interaction.ask(:workflow_confirm"
    end

    test "the policy denies workflow confirmations, collapsing to a single task" do
      # `task_split` maps a non-approve answer to `:run_as_single`, which is
      # exactly the CI behaviour: one checkout, no worktrees.
      assert Yoke.Interaction.Policy.ask(:workflow_confirm, %{cwd: "/nonexistent"}) == :deny
    end
  end
end
