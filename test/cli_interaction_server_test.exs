defmodule Yoke.CLI.InteractionServerTest do
  use ExUnit.Case, async: false
  # `Yoke.CLI.InteractionServer` is a supervised process.
  # See `test/test_helper.exs`.
  @moduletag :app

  alias Yoke.CLI.InteractionServer
  alias Yoke.CLI.QuestionPrompt
  alias Yoke.TaskEngine.PackageTracker

  setup do
    prior = Application.get_env(:yoke, :god_mode)
    Application.put_env(:yoke, :god_mode, true)

    on_exit(fn ->
      if prior == nil do
        Application.delete_env(:yoke, :god_mode)
      else
        Application.put_env(:yoke, :god_mode, prior)
      end
    end)

    :ok
  end

  describe "InteractionServer mailbox synchronization" do
    test "processes interaction requests sequentially through process mailbox" do
      # Spawn 5 concurrent tasks that all request single questions via InteractionServer
      tasks =
        Enum.map(1..5, fn i ->
          Task.async(fn ->
            InteractionServer.ask_single_question(
              "Question #{i}?",
              ["Option #{i}A", "Option #{i}B"]
            )
          end)
        end)

      results = Task.await_many(tasks, 5000)

      # Ensure all tasks successfully received their answers from the mailbox queue
      assert length(results) == 5

      Enum.each(Enum.with_index(results, 1), fn {res, i} ->
        assert res == %{selected: ["Option #{i}A (Recommended)"]}
      end)
    end

    test "handles batch ask/2 questions through mailbox" do
      questions = [
        %{"question" => "First question?", "options" => ["A", "B"]},
        %{"question" => "Second question?", "options" => ["C", "D"]}
      ]

      result = InteractionServer.ask(questions)
      assert {:ok, decoded1} = Jason.decode(List.first(String.split(result, "\n\n")))
      assert decoded1["status"] == "answered"
    end

    test "identifies subagent callers and passes subagent label metadata" do
      # Register calling process as a subagent package
      sub_id = "sub_test_#{System.unique_integer([:positive])}"

      Task.async(fn ->
        PackageTracker.register("sub: test subagent work", :subagent, id: sub_id)

        try do
          # Single question call will detect subagent label from PackageTracker
          state =
            QuestionPrompt.new_state(
              "Sub question?",
              ["Yes", "No"],
              false,
              2,
              true,
              nil,
              "sub: test subagent work"
            )

          assert state.subagent == "sub: test subagent work"
        after
          PackageTracker.unregister()
        end
      end)
      |> Task.await()
    end

    test "executes directly when self() is InteractionServer process" do
      pid = Process.whereis(InteractionServer)
      assert is_pid(pid)

      # Executing inside InteractionServer process avoids GenServer.call deadlock
      res =
        :erlang.apply(
          fn ->
            InteractionServer.ask_single_question("Self test?", ["Yes", "No"])
          end,
          []
        )

      assert res == %{selected: ["Yes (Recommended)"]}
    end
  end
end
