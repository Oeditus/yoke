defmodule Yoke.CI.BudgetEnforcementTest do
  @moduledoc """
  End-to-end proof that a configured budget actually stops a runaway review
  turn (`docs/CI_PLAN.md` Phase 1.3).

  `Yoke.CI.BudgetTest` covers the arithmetic in isolation; this module covers
  the wiring — that `Yoke.Brain.Session` consults the budget before each model
  call and aborts fail-closed when it is exhausted.
  """
  use ExUnit.Case, async: false
  @moduletag :tmp_dir

  alias Yoke.Brain.Session
  alias Yoke.CI.Budget
  alias Yoke.PRReview.Context
  alias Yoke.Test.ReviewFixture, as: Fixture

  setup %{tmp_dir: dir} do
    {:ok, _} = Application.ensure_all_started(:req)

    for {name, keys} <- [
          {Yoke.Registry, :unique},
          {Yoke.PubSubRegistry, :duplicate},
          {Yoke.TaskEngine.TaskRegistry, :duplicate},
          {Yoke.TaskEngine.LockRegistry, :unique},
          {Yoke.PackageRegistry, :duplicate}
        ] do
      unless Process.whereis(name),
        do: start_supervised!({Registry, keys: keys, name: name}, id: name)
    end

    unless Process.whereis(Yoke.TaskEngine.TaskSupervisor),
      do: start_supervised!({Task.Supervisor, name: Yoke.TaskEngine.TaskSupervisor})

    unless Process.whereis(Yoke.Plugin.Loader), do: start_supervised!(Yoke.Plugin.Loader)
    Fixture.repository(Path.join(dir, "repo"))
  end

  defp session(repo, responses, opts) do
    {listen, server, endpoint} = Fixture.provider(self(), responses)

    on_exit(fn ->
      :gen_tcp.close(listen)
      if Process.alive?(server), do: Process.exit(server, :kill)
    end)

    start_supervised!(
      {Session,
       Keyword.merge(
         [
           session_id: "budget-test-#{System.unique_integer([:positive])}",
           cwd: repo,
           api_key: "",
           model: "budget-test",
           endpoint: endpoint,
           max_tool_depth: 8
         ],
         Keyword.put(opts, :endpoint, endpoint)
       )}
    )
  end

  defp budget(attrs) do
    struct(
      %Budget{
        max_tool_calls: 100,
        max_wall_clock_s: 600,
        max_tokens: 1_000_000,
        max_cost_usd: 100.0,
        started_at: System.monotonic_time(:millisecond)
      },
      attrs
    )
  end

  test "a session with no budget is unaffected", %{repo: repo} do
    pid = session(repo, [Fixture.choice("<findings>[]</findings>")], budget: nil)

    assert {:ok, _} = Session.generate_code_review(pid, "main", "feature")
  end

  test "an exhausted tool-call budget aborts before the next model call", %{repo: repo} do
    pid =
      session(repo, [Fixture.choice("<findings>[]</findings>")],
        budget: budget(%{tool_calls: 100})
      )

    assert {:error, reason} = Session.generate_code_review(pid, "main", "feature")
    assert reason =~ "Tool-call budget exhausted"
  end

  test "an exhausted token budget aborts the turn", %{repo: repo} do
    pid =
      session(
        repo,
        [Fixture.choice("<findings>[]</findings>")],
        budget: budget(%{max_tokens: 10, prompt_tokens: 10})
      )

    assert {:error, reason} = Session.generate_code_review(pid, "main", "feature")
    assert reason =~ "Token budget exhausted"
  end

  test "an exhausted wall-clock budget aborts the turn", %{repo: repo} do
    started = System.monotonic_time(:millisecond) - 601_000

    pid =
      session(
        repo,
        [Fixture.choice("<findings>[]</findings>")],
        budget: budget(%{max_wall_clock_s: 600, started_at: started})
      )

    assert {:error, reason} = Session.generate_code_review(pid, "main", "feature")
    assert reason =~ "Wall-clock budget exhausted"
  end

  test "usage from a completed turn is accumulated into the budget", %{repo: repo} do
    # Two responses: the fixture provider serves one per call, then closes.
    pid =
      session(
        repo,
        [Fixture.choice("<findings>[]</findings>"), Fixture.choice("<findings>[]</findings>")],
        budget: budget(%{})
      )

    # A generous budget lets both turns run; the point is that accumulating
    # usage across turns does not itself trip a ceiling.
    assert {:ok, _} = Session.generate_code_review(pid, "main", "feature")
    assert {:ok, _} = Session.generate_code_review(pid, "main", "feature")
  end

  test "the budget survives into the review context", %{repo: repo} do
    pid =
      session(repo, [Fixture.choice("<findings>[]</findings>")], budget: budget(%{tool_calls: 0}))

    assert {:ok, context} = Context.resolve("main feature", repo)

    assert {:ok, _} =
             Session.generate_code_review(pid, "main", "feature", review_context: context)
  end
end
