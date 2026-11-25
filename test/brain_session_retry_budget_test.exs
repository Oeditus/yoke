defmodule Yoke.Brain.SessionRetryBudgetTest do
  @moduledoc """
  Proves the harness and the HTTP client share one cumulative retry budget.

  Issue #22 reports a turn that spent roughly twelve minutes retrying: the
  HTTP client retried transport closures and the harness retried the whole
  turn, each with its own counter, so the user saw two unrelated progress
  sequences and no overall bound. These tests pin the single-budget behavior
  at the session level using a local fake provider, so no network access or
  credentials are involved.
  """
  use ExUnit.Case, async: false
  @moduletag :tmp_dir

  alias Yoke.Brain.Session
  alias Yoke.Brain.SessionSupervisor
  alias Yoke.Client.RetryBudget

  setup do
    prior = Application.get_env(:yoke, :interaction)
    prior_god = Application.get_env(:yoke, :god_mode)
    Application.put_env(:yoke, :interaction, Yoke.Test.StubInteraction)
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

  describe "turn retry budget" do
    test "a new turn starts with no recorded retry budget" do
      pid = session(start_closing_provider())
      stats = Session.get_token_stats(pid)

      # Before any model call there is nothing to report.
      assert Map.get(stats, :retry_budget) == nil
    end

    test "a failing turn reports one attempt count and stops at the breaker", %{tmp_dir: cwd} do
      {endpoint, cleanup} = start_closing_provider()
      on_exit(cleanup)

      pid =
        session_with_opts(
          session_id: "retry-budget-#{System.unique_integer([:positive])}",
          cwd: cwd,
          endpoint: endpoint,
          api_key: "test-key",
          mock: false,
          retry_budget: [max_attempts: 4, identical_failure_limit: 2, max_backoff_ms: 1]
        )

      # The stub interaction denies the post-failure retry prompt, so the turn
      # returns an error instead of prompting a human.
      assert {:error, reason} = Session.send_user_message(pid, "hello")

      # The failure names the transport error and the payload size, which is
      # the diagnostic information issue #22 asks for.
      assert reason =~ "Request size: payload"
      assert reason =~ "attempt"

      # The harness must not run its own independent retry sequence on top of
      # the client's: the turn stops once the shared budget halts.
      refute_received {:stub_interaction, :api_error, _}
    end

    test "the harness reuses the budget stored in session state" do
      pid = session(start_closing_provider())

      # Seed a budget that is already exhausted, as if the client had spent it.
      spent = %{RetryBudget.new(max_attempts: 1) | attempts: 1}
      :sys.replace_state(pid, &Map.put(&1, :retry_budget, spent))

      stats = Session.get_token_stats(pid)
      assert %{summary: summary} = stats.retry_budget
      assert summary =~ "1 attempt in"
      assert summary =~ "limit 1 attempts"
    end
  end

  describe "retry budget configuration" do
    test "config defaults bound the retry budget" do
      config = Yoke.Config.load_config(".")

      assert config["api_retry_max_attempts"] == 6
      assert config["api_retry_total_timeout_ms"] == 120_000
      assert config["api_retry_max_backoff_ms"] == 8_000
      assert config["api_retry_identical_failure_limit"] == 2
    end

    test "the compiled defaults match the documented config defaults" do
      budget = RetryBudget.new()

      assert budget.max_attempts == 6
      assert budget.total_timeout_ms == 120_000
      assert budget.max_backoff_ms == 8_000
      assert budget.identical_failure_limit == 2
    end
  end

  defp session({endpoint, cleanup}) do
    on_exit(cleanup)

    session_with_opts(
      session_id: "retry-budget-#{System.unique_integer([:positive])}",
      cwd: System.tmp_dir!(),
      endpoint: endpoint,
      api_key: "test-key",
      mock: false
    )
  end

  defp session_with_opts(opts) do
    {:ok, pid} = SessionSupervisor.start_session(opts)

    on_exit(fn ->
      if Process.alive?(pid), do: SessionSupervisor.stop_session(pid)
    end)

    pid
  end

  # A local listener that accepts and immediately closes every connection,
  # reproducing the `%Req.TransportError{reason: :closed}` failure from the
  # issue without any network access.
  defp start_closing_provider do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, {_, port}} = :inet.sockname(listen)
    acceptor = spawn(fn -> close_loop(listen) end)

    cleanup = fn ->
      :gen_tcp.close(listen)
      if Process.alive?(acceptor), do: Process.exit(acceptor, :kill)
    end

    {"http://127.0.0.1:#{port}/v1/chat/completions", cleanup}
  end

  defp close_loop(listen) do
    case :gen_tcp.accept(listen, 5_000) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        close_loop(listen)

      {:error, _} ->
        :ok
    end
  end
end
