defmodule Yoke.Workflow.StepsTest do
  use ExUnit.Case, async: true

  alias Yoke.Workflow.Steps.Branch
  alias Yoke.Workflow.Steps.Commit
  alias Yoke.Workflow.Steps.Prompt
  alias Yoke.Workflow.Steps.TaskDescription
  alias Yoke.Workflow.Steps.TaskSplit

  describe "Steps.Branch.branch_name/2" do
    test "joins the prefix and run id into a deterministic branch name" do
      assert Branch.branch_name("yoke/elixir", "elixir-1730000000-ab12cd") ==
               "yoke/elixir/elixir-1730000000-ab12cd"
    end
  end

  describe "Steps.TaskSplit.extract_json_object/1" do
    test "extracts a bare JSON object" do
      assert {:ok, ~s({"subtasks": []})} = TaskSplit.extract_json_object(~s({"subtasks": []}))
    end

    test "extracts JSON wrapped in prose and a code fence" do
      text =
        "Sure, here you go:\n```json\n{\"subtasks\": [{\"id\": \"a\"}]}\n```\nHope that helps!"

      assert {:ok, json} = TaskSplit.extract_json_object(text)
      assert json =~ ~s("subtasks")
    end

    test "returns :error when there is no JSON object at all" do
      assert :error = TaskSplit.extract_json_object("no json here")
    end
  end

  describe "Steps.TaskSplit.extract_subtasks/1" do
    test "normalizes a valid multi-subtask response" do
      text = ~s({"subtasks": [
        {"id": "Backend API", "summary": "Add the endpoint", "owns": ["lib/api.ex"]},
        {"summary": "Add the UI"}
      ]})

      assert {:ok, subtasks} = TaskSplit.extract_subtasks(text)

      assert [%{"id" => "backend-api", "summary" => "Add the endpoint"}, %{"id" => "task-2"}] =
               subtasks
    end

    test "succeeds with an empty list for an empty subtasks array (build_plan/1 is what collapses this to no-split)" do
      assert {:ok, []} = TaskSplit.extract_subtasks(~s({"subtasks": []}))
    end

    test "rejects malformed JSON" do
      assert {:error, :unparseable} = TaskSplit.extract_subtasks("not json at all")
    end

    test "rejects a subtask missing a summary" do
      assert {:error, :unparseable} = TaskSplit.extract_subtasks(~s({"subtasks": [{"id": "a"}]}))
    end
  end

  describe "Steps.TaskSplit.build_plan/1" do
    test "keeps a split with more than one subtask" do
      text = ~s({"subtasks": [{"summary": "a"}, {"summary": "b"}]})
      assert %{"subtasks" => subtasks} = TaskSplit.build_plan(text)
      assert length(subtasks) == 2
    end

    test "collapses to no split when the model declines or the response is unparseable" do
      assert %{"subtasks" => []} = TaskSplit.build_plan(~s({"subtasks": []}))
      assert %{"subtasks" => []} = TaskSplit.build_plan("I cannot split this task.")
    end

    test "collapses to no split when only a single subtask comes back" do
      assert %{"subtasks" => []} =
               TaskSplit.build_plan(~s({"subtasks": [{"summary": "only one"}]}))
    end
  end

  describe "Steps.Prompt.interpolate/2" do
    test "substitutes known placeholders from the workflow context" do
      context = %{
        task_description: "Add login",
        branch: "yoke/elixir/run-1",
        workflow: %{name: "elixir"},
        run_id: "elixir-1-ab"
      }

      template = "Task: {{task_description}} on {{branch}} for workflow {{workflow}} ({{run_id}})"

      assert Prompt.interpolate(template, context) ==
               "Task: Add login on yoke/elixir/run-1 for workflow elixir (elixir-1-ab)"
    end

    test "leaves unknown placeholders untouched" do
      context = %{workflow: %{name: "elixir"}, run_id: "x"}
      assert Prompt.interpolate("{{nope}}", context) == "{{nope}}"
    end
  end

  describe "prompt builders include the relevant context" do
    test "TaskDescription.prompt/1 includes the seed text" do
      assert TaskDescription.prompt("Add dark mode") =~ "Add dark mode"
    end

    test "TaskSplit.split_prompt/1 includes the task description" do
      assert TaskSplit.split_prompt("Add dark mode") =~ "Add dark mode"
    end

    test "Commit.commit_prompt/1 includes the diff text" do
      assert Commit.commit_prompt("diff --git a/x b/x") =~ "diff --git a/x b/x"
    end
  end
end
