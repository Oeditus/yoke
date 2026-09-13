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
      :phase,       # :input | :output | :tool_call
      :target,      # tool name or model ID
      :action,      # :pass | :flagged | :blocked
      :mode,        # :observe | :enforce
      :reason,      # string or nil
      :details,     # map of extra info
      :timestamp,   # ISO8601 string
      :duration_ms  # integer latency
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

  @audit_file ".yoke/logs/ai_guard_audit.jsonl"

  # Risk patterns for input/prompt injection and credentials
  @secret_patterns [
    {~r/(?:sk-|ghp_|gho_|glpat-|xox[baprs]-)[A-Za-z0-9_\-]{20,}/, "Potential API Token / Private Secret"},
    {~r/-----BEGIN (?:RSA|OPENSSH|EC|PRIVATE KEY)-----/, "Private Key Material"},
    {~r/DEEPSEEK_API_KEY\s*=\s*['"]?[A-Za-z0-9_\-]+['"]?/, "DeepSeek API Key leakage"}
  ]

  @destructive_cmd_patterns [
    {~r/rm\s+-rf\s+(?:\/|\/\*|~|\$HOME)$/, "Destructive root/home directory deletion (rm -rf)"},
    {~r/:\(\)\s*\{\s*:\|:&\s*\};\s*:/, "Fork bomb pattern"},
    {~r/>\s*\/dev\/sd[a-z]/, "Raw disk device overwrite"},
    {~r/mkfs\./, "Filesystem format command"}
  ]

  @prompt_injection_patterns [
    {~r/ignore\s+(?:all\s+)?previous\s+instructions/i, "Prompt injection: reset instructions attempt"},
    {~r/system\s+prompt\s+override/i, "Prompt injection: override attempt"}
  ]

  @doc "Evaluates an LLM request prompt or response completion."
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

    log_and_audit(verdict)
    verdict
  end

  @doc "Evaluates a tool call and its arguments before execution."
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

    log_and_audit(verdict)
    verdict
  end

  @doc "Retrieves recent audit log entries."
  def audit_log(cwd \\ ".") do
    path = Path.join(cwd, @audit_file)

    if File.exists?(path) do
      path
      |> File.stream!()
      |> Enum.map(fn line ->
        case Yoke.Json.decode(line) do
          {:ok, map} -> map
          _ -> nil
        end
      end)
      |> Enum.reject(&is_nil/1)
    else
      []
    end
  end

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
      messages
      |> Enum.map(fn
        %{"content" => c} when is_binary(c) -> c
        %{content: c} when is_binary(c) -> c
        c when is_binary(c) -> c
        _ -> ""
      end)
      |> Enum.join("\n")

    check_patterns(text, patterns)
  end

  defp check_patterns(_, _), do: []

  defp evaluate_tool_risk(tool_name, %{} = args) do
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

  defp log_and_audit(%Verdict{} = verdict) do
    if verdict.action in [:flagged, :blocked] do
      msg = "[AI Guard:#{verdict.mode}] #{verdict.phase} on target '#{verdict.target}': #{verdict.reason}"

      case verdict.action do
        :blocked -> Logger.error(msg)
        :flagged -> Logger.warning(msg)
        :pass -> nil
      end
    end

    write_audit_entry(verdict)
  end

  defp write_audit_entry(%Verdict{} = verdict) do
    entry = %{
      "timestamp" => verdict.timestamp,
      "phase" => to_string(verdict.phase),
      "target" => verdict.target,
      "action" => to_string(verdict.action),
      "mode" => to_string(verdict.mode),
      "reason" => verdict.reason,
      "duration_ms" => verdict.duration_ms
    }

    try do
      path = @audit_file
      File.mkdir_p!(Path.dirname(path))
      line = Yoke.Json.encode!(entry) <> "\n"
      File.write!(path, line, [:append])
    rescue
      _ -> :ok
    end
  end
end
