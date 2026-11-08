defmodule Yoke.TaskEngine.PackageTrackerTest do
  @moduledoc """
  Tests for `Yoke.TaskEngine.PackageTracker`, the registry that
  surfaces long-running named parallel packages (subagents, workflow
  subtasks) to the status bar.
  """
  use ExUnit.Case, async: false
  # `Yoke.TaskEngine.PackageTracker` writes to `Yoke.PackageRegistry`.
  # See `test/test_helper.exs`.
  @moduletag :app

  alias Yoke.TaskEngine.PackageTracker

  setup do
    # Ensure a clean slate between tests.
    on_exit(fn ->
      PackageTracker.list()
      |> Enum.each(fn %{id: _id} -> :ok end)
    end)

    :ok
  end

  test "register returns an id and list surfaces the label" do
    {:ok, id} = PackageTracker.register("[A] plan_gate", :subagent)
    assert is_binary(id)

    packages = PackageTracker.list()
    assert Enum.any?(packages, fn p -> p.id == id and p.label == "[A] plan_gate" end)
  end

  test "list_labels joins labels for the status bar" do
    {:ok, _} = PackageTracker.register("[A] plan_gate", :subagent)
    {:ok, _} = PackageTracker.register("[B] config", :subagent)

    assert PackageTracker.list_labels() =~ "[A] plan_gate"
    assert PackageTracker.list_labels() =~ "[B] config"
  end

  test "unregister removes the calling process's package" do
    parent = self()

    {pid, _ref} =
      spawn_monitor(fn ->
        {:ok, id} = PackageTracker.register("worker", :subagent)
        send(parent, {:registered, id})
        # Wait until told to unregister
        receive do
          :go -> PackageTracker.unregister()
        after
          5_000 -> :ok
        end
      end)

    assert_receive {:registered, id}, 1_000
    assert Enum.any?(PackageTracker.list(), &(&1.id == id))

    send(pid, :go)
    assert_receive {:DOWN, _ref, :process, ^pid, _reason}, 1_000

    # Give the unregister a moment to propagate.
    Process.sleep(20)
    refute Enum.any?(PackageTracker.list(), &(&1.id == id))
  end

  test "a crashed package process auto-unregisters (no stale label)" do
    parent = self()

    {pid, _ref} =
      spawn_monitor(fn ->
        {:ok, id} = PackageTracker.register("crashy", :workflow_subtask)
        send(parent, {:registered, id})

        receive do
          :crash -> exit(:boom)
        end
      end)

    assert_receive {:registered, id}, 1_000
    assert Enum.any?(PackageTracker.list(), &(&1.id == id))

    send(pid, :crash)
    assert_receive {:DOWN, _ref, :process, ^pid, :boom}, 1_000
    Process.sleep(20)
    refute Enum.any?(PackageTracker.list(), &(&1.id == id))
  end
end
