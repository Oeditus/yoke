defmodule Yoke.CLI.Fix do
  @moduledoc """
  `yoke fix` -- pick up the last command from the terminal history, replay it
  inside Yoke, analyse the failure(s), and produce a concrete fix plan.

  ## Flow

  1. **Locate the command.** `Yoke.ShellHistory.last_command/1` reads the
     user's shell history (zsh extended format, bash, fish), or an explicit
     command given on the command line. Yoke's own invocations are skipped, so
     running `yoke fix` twice analyses the failing command, not the previous
     `yoke fix`.
  2. **Replay it** in the current workspace, capturing stdout+stderr and the
     exit status. `--no-run` skips this and analyses the command statically.
  3. **Analyse** the captured output: exit status, compiler/test error
     signatures (Elixir, Rust, Node, Python, Go, C/C++), and the first
     offending `file:line` locations.
  4. **Plan.** Prints a triage report, then hands the whole thing to the Brain
     actor as a prompt so the agent investigates and proposes (and, with
     `--apply`, executes) the fix.

  ## Exit codes

    0  the replayed command succeeded (nothing to fix)
    1  the replayed command failed and a fix plan was produced
    2  usage error
    3  no command could be determined from history
  """

  alias Yoke.CLI.Formatter
  alias Yoke.ShellHistory

  @switches [
    no_run: :boolean,
    apply: :boolean,
    plan_only: :boolean,
    previous: :boolean,
    command: :string,
    history_file: :string,
    timeout: :integer,
    agent_timeout: :integer,
    help: :boolean,
    session: :string
  ]

  @aliases [h: :help, n: :no_run, a: :apply, p: :previous]

  # Upper bound on captured output fed to the model. A failing `mix test` can
  # emit megabytes; the model only needs the head (first failures) and the
  # tail (summary), so the middle is elided.
  @max_capture_chars 24_000

  # How long the analysis turn may run before `yoke fix` gives up and reports
  # that the triage is still valid. The underlying call chain uses `:infinity`
  # timeouts, so this is the only thing standing between a stalled provider and
  # a permanently wedged CLI.
  @default_agent_timeout_ms 600_000

  # How long to wait for a session to shut down before killing it outright.
  @shutdown_timeout_ms 5_000

  @doc "Entry point invoked by `Yoke.CLI.Main`'s dispatch table for `yoke fix`."
  @spec fix([String.t()]) :: non_neg_integer()
  def fix(args) do
    {opts, extra, invalid} = OptionParser.parse(args, strict: @switches, aliases: @aliases)

    cond do
      opts[:help] ->
        IO.puts(usage())
        0

      invalid != [] ->
        IO.puts(Formatter.format_error("Unknown or malformed option(s): #{inspect(invalid)}"))
        IO.puts(usage())
        2

      true ->
        run(opts, extra)
    end
  end

  @doc "Returns the usage text for `yoke fix`."
  @spec usage() :: String.t()
  def usage do
    """
    yoke fix — replay the last terminal command, analyse the failure, and plan a fix

    USAGE:
      yoke fix [options] ["<command>"]

    Reads the most recent command from your shell history (zsh, bash or fish),
    re-runs it here, and asks the agent to diagnose the failure and propose a
    concrete fix plan.

    OPTIONS:
      -n, --no-run            Do not re-run the command; analyse it statically
      -a, --apply             Let the agent apply the fix (default: plan only)
          --plan-only         Print the triage and the exact prompt that would be
                              sent to the agent, then stop (no session, no model
                              turn)
      -p, --previous          Use the command *before* the last one
          --command <cmd>     Use this command instead of the shell history
          --history-file <p>  Read shell history from this file
          --timeout <ms>      Kill the replayed command after this long
                              (default: 600000 = 10 minutes)
          --agent-timeout <ms> Give up on the analysis turn after this long
                              (default: 600000 = 10 minutes)
          --session <id>      Resume/continue the given Yoke session
      -h, --help              Show this help

    EXAMPLES:
      yoke fix                       # replay the last command, explain the failure
      yoke fix --apply               # …and let the agent fix it
      yoke fix "mix test test/foo_test.exs:42"
      yoke fix --no-run              # just plan, do not execute anything

    EXIT CODES:
      0  the replayed command succeeded
      1  the command failed and a fix plan was produced
      2  usage error
      3  no command could be determined from history
    """
  end

  # ---------------------------------------------------------------------
  # Orchestration
  # ---------------------------------------------------------------------

  defp run(opts, extra) do
    case resolve_command(opts, extra) do
      {:ok, command, source} ->
        IO.puts(Formatter.format_info("Command source: #{source}"))
        IO.puts(Formatter.format_info("Command: #{command}"))

        outcome = maybe_run(command, opts)

        print_triage(command, outcome)

        case outcome do
          %{status: 0} ->
            IO.puts(Formatter.format_success("Command succeeded — nothing to fix."))
            0

          _ ->
            prompt = build_prompt(command, outcome, opts)
            hand_off(command, prompt, opts)
        end

      {:error, reason} ->
        IO.puts(Formatter.format_error(reason))
        3
    end
  end

  # `--plan-only` prints the exact prompt that would be sent to the agent and
  # stops. It exists so the triage/plan half of `yoke fix` can be inspected --
  # and tested -- without starting a session and spending a live model turn.
  defp hand_off(_command, prompt, opts) do
    if opts[:plan_only] do
      IO.puts(
        Formatter.format_info(
          "Plan-only mode: the following prompt would be sent to the agent.\n"
        )
      )

      IO.puts(prompt)
      1
    else
      dispatch_to_agent(prompt, opts)
    end
  end

  # An explicit command (flag or positional args) wins over shell history.
  defp resolve_command(opts, extra) do
    inline = String.trim(opts[:command] || Enum.join(extra, " "))

    if inline != "" do
      {:ok, inline, "command line"}
    else
      history_opts =
        [skip: if(opts[:previous], do: 1, else: 0)]
        |> maybe_put(:history_file, opts[:history_file])

      with {:ok, command} <- ShellHistory.last_command(history_opts) do
        {:ok, command, "shell history"}
      end
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp maybe_run(command, opts) do
    if opts[:no_run] do
      %{status: nil, output: "", duration_ms: 0, ran?: false}
    else
      execute(command, opts)
    end
  end

  defp execute(command, opts) do
    timeout = opts[:timeout] || 600_000
    started = System.monotonic_time(:millisecond)

    IO.puts(Formatter.format_info("Re-running the command (timeout #{div(timeout, 1000)}s)…\n"))

    task =
      Task.async(fn ->
        System.cmd("sh", ["-c", command], stderr_to_stdout: true, into: "")
      end)

    result =
      case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
        {:ok, {output, status}} -> {output, status}
        nil -> {"<timed out after #{timeout}ms>", 124}
      end

    {output, status} = result
    duration_ms = System.monotonic_time(:millisecond) - started

    %{status: status, output: output, duration_ms: duration_ms, ran?: true}
  end

  # ---------------------------------------------------------------------
  # Triage report
  # ---------------------------------------------------------------------

  @doc """
  Extracts the most useful diagnostics from a captured command output.

  Returns a map with `:status`, `:signatures` (recognised failure kinds),
  `:locations` (first `file:line` references) and `:summary` (the last few
  non-empty lines, which is where compilers put their summary).
  """
  @spec analyze(String.t(), integer() | nil) :: map()
  def analyze(output, status) do
    lines = String.split(output || "", "\n")

    %{
      status: status,
      signatures: signatures(output || ""),
      locations: locations(lines),
      summary: lines |> Enum.reject(&(String.trim(&1) == "")) |> Enum.take(-15)
    }
  end

  # Ordered so the most specific/actionable signature wins the "primary" slot.
  @signatures [
    {"Elixir compile error",
     ~r/\*\* \(CompileError\)|\*\* \(SyntaxError\)|\*\* \(TokenMissingError\)/},
    {"Elixir test failure", ~r/\d+\) test .*\(.*\)\n|\*\* \(ExUnit\.AssertionError\)/},
    {"Elixir warning-as-error", ~r/could not compile .* because|Compilation error/},
    {"Rust compile error", ~r/^error\[E\d+\]:|^error: could not compile/m},
    {"Node/TypeScript error", ~r/error TS\d+:|^npm ERR!|Cannot find module/},
    {"Python traceback", ~r/^Traceback \(most recent call last\):/m},
    {"Go build error", ~r/^# .*\n.*\.go:\d+:\d+:/m},
    {"C/C++ build error", ~r/error: .*\.(c|cc|cpp|h|hpp):\d+|undefined reference to/},
    {"Dependency resolution",
     ~r/Could not find a Mix.Project|mix deps\.get|No such file or directory \(os error 2\)/},
    {"Permission denied", ~r/Permission denied/},
    {"Command not found", ~r/command not found|: not found$/},
    {"Network/connection", ~r/Connection refused|Could not resolve host|timeout/}
  ]

  defp signatures(output) do
    for {name, regex} <- @signatures, Regex.match?(regex, output), do: name
  end

  defp locations(lines) do
    lines
    |> Enum.flat_map(fn line ->
      Regex.scan(~r/([\w.\-\/]+\.\w{1,5}):(\d+)(?::(\d+))?/, line, capture: :all_but_first)
    end)
    |> Enum.map(fn
      [file, line, col] -> "#{file}:#{line}:#{col}"
      [file, line] -> "#{file}:#{line}"
    end)
    |> Enum.uniq()
    |> Enum.take(20)
  end

  defp print_triage(command, outcome) do
    analysis = analyze(outcome.output, outcome.status)

    status_line =
      cond do
        not outcome.ran? -> "not re-run (`--no-run`)"
        outcome.status == 0 -> "succeeded"
        true -> "FAILED with exit status #{outcome.status}"
      end

    signatures =
      case analysis.signatures do
        [] -> "  (no recognised error signature)"
        sigs -> Enum.map_join(sigs, "\n", &"  • #{&1}")
      end

    locations =
      case analysis.locations do
        [] -> "  (none found)"
        locs -> Enum.map_join(Enum.take(locs, 10), "\n", &"  • #{&1}")
      end

    summary =
      case analysis.summary do
        [] -> "  (no output)"
        lines -> Enum.map_join(lines, "\n", &"  │ #{&1}")
      end

    md = """
    ### Fix Triage

    - **Command**: `#{command}`
    - **Result**: #{status_line}
    - **Duration**: #{outcome.duration_ms}ms
    - **Recognised failures**:
    #{signatures}
    - **Offending locations**:
    #{locations}

    **Tail of the output**

    ```
    #{summary}
    ```
    """

    IO.puts("\n" <> Formatter.format_markdown(md) <> "\n")
  end

  # ---------------------------------------------------------------------
  # Agent hand-off
  # ---------------------------------------------------------------------

  @doc """
  Builds the prompt handed to the Brain actor describing the failed command,
  its captured output, and the exact deliverable expected.
  """
  @spec build_prompt(String.t(), map(), keyword()) :: String.t()
  def build_prompt(command, outcome, opts \\ []) do
    analysis = analyze(outcome.output, outcome.status)
    apply? = Keyword.get(opts, :apply, false)

    deliverable =
      if apply? do
        """
        You MAY now apply the fix: edit the files, then re-run the command to
        prove it passes. Keep the change minimal and idiomatic for this
        codebase, and report the final diff summary.
        """
      else
        """
        Do NOT modify files yet. Produce the fix plan only: for each root
        cause, name the file and line, explain why it fails, and give the
        concrete edit you propose. End with a numbered checklist the user can
        approve.
        """
      end

    run_note =
      if outcome.ran? do
        "The command was re-run inside Yoke and its output captured below."
      else
        "The command was NOT re-run (`--no-run`); analyse it statically."
      end

    """
    ### `yoke fix` — diagnose the last failed terminal command

    **Command**

    ```
    #{command}
    ```

    **Exit status**: #{inspect(outcome.status)}
    **Recognised failure kinds**: #{Enum.join(analysis.signatures, ", ")}
    **Offending locations**: #{Enum.join(analysis.locations, ", ")}

    #{run_note}

    **Captured output**

    ```
    #{truncate_output(outcome.output)}
    ```

    ### Your task

    1. Identify the ROOT CAUSE(S) of the failure — not just the first error
       line. Group cascading errors under the cause that produced them.
    2. For each root cause, cite the exact `file:line` and explain the defect.
    3. Propose the concrete fix (the edit you would make), and note any
       follow-up verification step (a narrower test, a type check, a lint).
    4. Flag anything that looks like an environment/toolchain problem rather
       than a code defect, and say how to confirm it.

    #{deliverable}
    """
  end

  # Keeps the head (first failures, where compilers start) and the tail
  # (summary counts), eliding the middle so a huge log still fits a prompt.
  defp truncate_output(output) when is_binary(output) do
    if String.length(output) <= @max_capture_chars do
      output
    else
      half = div(@max_capture_chars, 2)
      head = String.slice(output, 0, half)
      tail = String.slice(output, -half, half)
      elided = String.length(output) - 2 * half
      head <> "\n\n… [#{elided} characters elided] …\n\n" <> tail
    end
  end

  defp truncate_output(_), do: ""

  # Hands the triage prompt to a Brain actor. Every failure mode here -- the
  # supervisor not running, the session crashing, the turn erroring, the model
  # taking forever -- must still exit with the "a plan was produced" code (1)
  # and a readable message, never an unhandled exit and never an unbounded
  # wait: the user already has the triage report on screen, so hanging is
  # strictly worse than giving up.
  #
  # The turn itself is bounded by `:agent_timeout` because the underlying
  # `send_user_message/2` is a `GenServer.call` with an `:infinity` timeout
  # wrapped around an HTTP request that also uses `receive_timeout: :infinity`.
  # Without a bound here, a stalled provider hangs `yoke fix` forever.
  defp dispatch_to_agent(prompt, opts) do
    session_id = opts[:session] || Yoke.CLI.Main.generate_uuid()
    timeout = opts[:agent_timeout] || @default_agent_timeout_ms

    case start_session(session_id) do
      {:ok, session_pid} ->
        try do
          run_turn(session_pid, prompt, timeout)
        after
          stop_session(session_pid)
        end

      {:error, reason} ->
        IO.puts(Formatter.format_error("Could not start a session: #{inspect(reason)}"))
        1
    end
  end

  defp start_session(session_id) do
    Yoke.Brain.SessionSupervisor.start_session(session_id: session_id)
  catch
    :exit, reason -> {:error, reason}
  end

  # `DynamicSupervisor.terminate_child/2` waits for the child to shut down, so
  # a session wedged in a network call would block here too. Bound it and fall
  # back to a hard kill.
  defp stop_session(pid) do
    task = Task.async(fn -> Yoke.Brain.SessionSupervisor.stop_session(pid) end)

    case Task.yield(task, @shutdown_timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, _} -> :ok
      nil -> Process.exit(pid, :kill)
    end
  catch
    :exit, _ -> :ok
  end

  defp run_turn(session_pid, prompt, timeout) do
    task = Task.async(fn -> Yoke.Brain.Session.send_user_message(session_pid, prompt) end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, %{content: content}}} ->
        IO.puts("\n" <> Formatter.format_agent_response(content) <> "\n")
        Formatter.flush()
        1

      {:ok, {:error, reason}} ->
        IO.puts(Formatter.format_error("Agent turn failed: #{reason}"))
        1

      {:ok, other} ->
        IO.puts(
          Formatter.format_error("Agent turn returned an unexpected result: #{inspect(other)}")
        )

        1

      nil ->
        IO.puts(
          Formatter.format_error(
            "Agent turn did not finish within #{div(timeout, 1000)}s; the triage above is still valid."
          )
        )

        1
    end
  catch
    :exit, reason ->
      IO.puts(Formatter.format_error("Agent turn crashed: #{inspect(reason)}"))
      1
  end
end
