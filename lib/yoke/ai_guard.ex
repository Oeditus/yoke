defmodule Yoke.AIGuard do
  @moduledoc """
  Dual-seam AI Guardrail & Audit Logger for Yoke.

  Guards against prompt injections, secret leakage, and destructive shell/file tool calls
  across two seams:
    1. LLM Calls (Input prompts & output model completions).
    2. Tool Executions (Tool call parameters before execution in Yoke.Hands.Executor).

  Operates in two modes:
    * `:observe` (default): Logs safety warnings and audit records without blocking execution.
    * `:enforce`: Blocks execution of tool calls or LLM prompts that violate safety constraints.
  """
  require Logger

  defmodule Verdict do
    @moduledoc "Represents an AI Guard evaluation verdict."
    defstruct [
      # :input | :output | :tool_call
      :phase,
      # tool name or model ID
      :target,
      # :pass | :flagged | :blocked
      :action,
      # :observe | :enforce
      :mode,
      # string or nil
      :reason,
      # map of extra info
      :details,
      # ISO8601 string
      :timestamp,
      # integer latency
      :duration_ms
    ]

    @type t :: %__MODULE__{
            phase: :input | :output | :tool_call,
            target: String.t(),
            action: :pass | :flagged | :blocked,
            mode: :observe | :enforce,
            reason: String.t() | nil,
            details: map(),
            timestamp: String.t(),
            duration_ms: non_neg_integer()
          }
  end

  @doc "Returns the repo-relative audit log path."
  @spec audit_file() :: String.t()
  def audit_file, do: Yoke.AIGuard.AuditLog.audit_file()

  # Risk patterns for input/prompt injection and credentials
  @secret_patterns [
    {~r/(?<![A-Za-z0-9_-])(?:sk-(?!(?:[a-z]+-+)+[a-z]+(?![A-Za-z0-9_-]))|ghp_|gho_|glpat-|xox[baprs]-)[A-Za-z0-9_\-]{20,}/,
     "Potential API Token / Private Secret"},
    {~r/-----BEGIN (?:RSA|OPENSSH|EC|PRIVATE KEY)-----/, "Private Key Material"},
    {~r/['"]?DEEPSEEK_API_KEY['"]?\s*[:=]\s*['"]?sk-[A-Za-z0-9_\-]{20,}['"]?/i,
     "DeepSeek API Key leakage"}
  ]

  @destructive_cmd_patterns [
    {~r/rm\s+-rf\s+(?:\/|\/\*|~|\$HOME)$/, "Destructive root/home directory deletion (rm -rf)"},
    {~r/:\(\)\s*\{\s*:\|:&\s*\};\s*:/, "Fork bomb pattern"},
    {~r/>\s*\/dev\/sd[a-z]/, "Raw disk device overwrite"},
    {~r/mkfs\./, "Filesystem format command"}
  ]

  @prompt_injection_patterns [
    {~r/ignore\s+(?:all\s+)?previous\s+instructions/i,
     "Prompt injection: reset instructions attempt"},
    {~r/system\s+prompt\s+override/i, "Prompt injection: override attempt"}
  ]

  @doc """
  Evaluates an LLM request prompt or response completion.

  `opts` accepts `:mode`, `:target`, and `:cwd` (the workspace whose audit log
  receives the entry; defaults to the process working directory).
  """
  def guard_llm(content, phase, opts \\ []) when phase in [:input, :output] do
    start_time = System.monotonic_time(:millisecond)
    mode = get_mode(opts)
    target = opts[:target] || "llm"

    checks =
      case phase do
        :input -> @secret_patterns ++ @prompt_injection_patterns
        :output -> @secret_patterns
      end

    violations = check_patterns(content, checks)

    action =
      cond do
        violations == [] -> :pass
        mode == :enforce -> :blocked
        true -> :flagged
      end

    reason = if violations != [], do: Enum.map_join(violations, "; ", &elem(&1, 1)), else: nil
    duration_ms = System.monotonic_time(:millisecond) - start_time

    verdict = %Verdict{
      phase: phase,
      target: target,
      action: action,
      mode: mode,
      reason: reason,
      details: %{violations_count: length(violations)},
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      duration_ms: duration_ms
    }

    log_and_audit(verdict, opts[:cwd] || ".")
    verdict
  end

  @doc """
  Evaluates a tool call and its arguments before execution.

  `opts`:

    * `:mode` -- `:observe` or `:enforce` (default: application env, else `:observe`)
    * `:cwd` -- workspace whose `.yoke/logs/ai_guard_audit.jsonl` receives the
      audit entry. Defaults to the process working directory.
  """
  def guard_tool(tool_name, args, opts \\ []) do
    start_time = System.monotonic_time(:millisecond)
    mode = get_mode(opts)

    violations = evaluate_tool_risk(tool_name, args)

    action =
      cond do
        violations == [] -> :pass
        mode == :enforce -> :blocked
        true -> :flagged
      end

    reason = if violations != [], do: Enum.map_join(violations, "; ", &elem(&1, 1)), else: nil
    duration_ms = System.monotonic_time(:millisecond) - start_time

    verdict = %Verdict{
      phase: :tool_call,
      target: to_string(tool_name),
      action: action,
      mode: mode,
      reason: reason,
      details: %{args_summary: Yoke.Hands.Executor.format_tool_call(tool_name, args)},
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      duration_ms: duration_ms
    }

    log_and_audit(verdict, opts[:cwd] || ".")
    verdict
  end

  @doc "Retrieves recent audit log entries for `cwd`."
  def audit_log(cwd \\ "."), do: Yoke.AIGuard.AuditLog.read(cwd)

  # Helper functions

  defp get_mode(opts) do
    cond do
      opts[:mode] in [:observe, :enforce] -> opts[:mode]
      mode = Application.get_env(:yoke, :ai_guard_mode) -> mode
      true -> :observe
    end
  end

  defp check_patterns(content, patterns) when is_binary(content) do
    Enum.filter(patterns, fn {regex, _desc} ->
      Regex.run(regex, content) != nil
    end)
  end

  defp check_patterns(messages, patterns) when is_list(messages) do
    text =
      Enum.map_join(messages, "\n", fn
        %{"content" => c} when is_binary(c) -> c
        %{content: c} when is_binary(c) -> c
        c when is_binary(c) -> c
        _ -> ""
      end)

    check_patterns(text, patterns)
  end

  defp check_patterns(_, _), do: []

  defp evaluate_tool_risk(_tool_name, %{} = args) do
    cmd = Map.get(args, "command") || Map.get(args, :command) || ""
    content = Map.get(args, "content") || Map.get(args, :content) || ""

    cmd_violations =
      if is_binary(cmd),
        do: check_patterns(cmd, @destructive_cmd_patterns ++ @secret_patterns),
        else: []

    content_violations =
      if is_binary(content), do: check_patterns(content, @secret_patterns), else: []

    cmd_violations ++ content_violations
  end

  defp evaluate_tool_risk(_, _), do: []

  defp log_and_audit(%Verdict{} = verdict, cwd) do
    if verdict.action in [:flagged, :blocked] do
      msg =
        "[AI Guard:#{verdict.mode}] #{verdict.phase} on target '#{verdict.target}': #{verdict.reason}"

      case verdict.action do
        :blocked -> Logger.error(msg)
        :flagged -> Logger.warning(msg)
      end
    end

    write_audit_entry(verdict, cwd)
  end

  defp write_audit_entry(%Verdict{} = verdict, cwd) do
    entry = %{
      "timestamp" => verdict.timestamp,
      "phase" => to_string(verdict.phase),
      "target" => verdict.target,
      "action" => to_string(verdict.action),
      "mode" => to_string(verdict.mode),
      "reason" => verdict.reason,
      "duration_ms" => verdict.duration_ms
    }

    case Yoke.Json.encode(entry) do
      {:ok, line} -> Yoke.AIGuard.AuditLog.append(cwd, line <> "\n")
      {:error, _} -> :ok
    end
  end
end
