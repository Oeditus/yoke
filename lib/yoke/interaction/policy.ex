defmodule Yoke.Interaction.Policy do
  @moduledoc """
  The headless implementation of `Yoke.Interaction`.

  It **never blocks** and **never asks**. Every `ask/2` returns a decision
  immediately, derived from a declarative policy document. This is what makes
  `yoke review` (and every later CI capability) runnable with
  `</dev/null` and no TTY.

  ## Fail-closed by default

  A missing policy file, a malformed policy file, or an unknown key all fall
  back to the safe answer for that kind -- `:deny` for everything except a
  plan gate whose `plan_gate` is explicitly `"approve"`. A CI run must never
  silently approve a destructive action because its config was unreadable.

  ## Policy document

  `.yoke/policy.json` (repo-relative), or the path in the `YOKE_POLICY`
  environment variable, which takes precedence:

  ```json
  {
    "plan_gate": "deny",
    "loop_break": "deny",
    "api_error": "deny",
    "max_depth": "deny",
    "tool_permission": "deny",
    "review_fix": "deny",
    "allow_writes": false,
    "fail_on": "high",
    "max_tool_calls": 120,
    "max_wall_clock_s": 900,
    "max_cost_usd": 2.0,
    "max_tokens": 400000
  }
  ```

  The per-kind keys accept `"approve"` or `"deny"`. `allow_writes` is a
  stricter, orthogonal switch consumed by `Yoke.Hands.Executor` in `:ci` mode
  and by `Yoke.CLI.CI` -- it is *not* consulted here, because a tool
  permission request already carries its own `:tool_permission` answer.

  ## Precedence

  1. `YOKE_POLICY` env var (a path) when set and readable.
  2. `<cwd>/.yoke/policy.json`.
  3. Built-in defaults (`@defaults`).

  The loader never reads or writes `~/.yoke`.
  """

  @behaviour Yoke.Interaction

  alias Yoke.Json

  @defaults %{
    "plan_gate" => "deny",
    "plan_revision" => "deny",
    "loop_break" => "deny",
    "api_error" => "deny",
    "max_depth" => "deny",
    "tool_permission" => "deny",
    "review_fix" => "deny",
    "allow_writes" => false,
    "fail_on" => "high",
    "max_tool_calls" => 120,
    "max_wall_clock_s" => 900,
    "max_cost_usd" => 2.0,
    "max_tokens" => 400_000,
    # Cap on the review diff size in bytes (see `Yoke.Git.max_diff_bytes/1`).
    "max_diff_bytes" => 300_000
  }

  @policy_path ".yoke/policy.json"

  @doc "Returns the built-in default policy map."
  @spec defaults() :: map()
  def defaults, do: @defaults

  @doc "Returns the repo-relative policy path."
  @spec policy_path() :: String.t()
  def policy_path, do: @policy_path

  @doc """
  Loads the effective policy for `cwd`.

  Always returns a fully-populated map: unknown/malformed values are dropped
  and replaced by `defaults/0`, so callers never have to guard against
  missing keys.
  """
  @spec load(String.t()) :: map()
  def load(cwd \\ ".") do
    @defaults
    |> Map.merge(read_policy_file(env_policy_path() || Path.join(cwd, @policy_path)))
    |> normalize()
  end

  @doc """
  Returns the effective policy as a JSON-encodable map (keys sorted for
  stable diffs when it is written to an artifact).
  """
  @spec to_report(String.t()) :: map()
  def to_report(cwd \\ "."), do: load(cwd)

  @doc """
  Writes a policy document to `<cwd>/.yoke/policy.json`.

  Used by tests and by `yoke --doctor` to scaffold a starting point. Returns
  `{:ok, path}` or `{:error, reason}`.
  """
  @spec write(String.t(), map()) :: {:ok, String.t()} | {:error, String.t()}
  def write(cwd, policy) when is_map(policy) do
    path = Path.join(cwd, @policy_path)

    with :ok <- File.mkdir_p(Path.dirname(path)),
         {:ok, json} <- Json.encode(policy, pretty: true),
         :ok <- File.write(path, json) do
      {:ok, path}
    else
      err -> {:error, "Failed to write policy to #{path}: #{inspect(err)}"}
    end
  end

  @impl true
  def ask(kind, context \\ %{}) do
    policy = policy_from(context)

    case Map.get(policy, Atom.to_string(kind), "deny") do
      "approve" -> :approve
      _ -> :deny
    end
  end

  @doc """
  Returns true when writes (file mutations and write-ish bash) are allowed by
  the effective policy.

  A PR review is read-only; this is a safety property, not a preference, so
  the default is `false`.
  """
  @spec allow_writes?(String.t()) :: boolean()
  def allow_writes?(cwd \\ ".") do
    Map.get(load(cwd), "allow_writes", false) == true
  end

  @doc "Returns the `--fail-on` severity threshold from the policy (`high` by default)."
  @spec fail_on(String.t()) :: String.t()
  def fail_on(cwd \\ "."), do: Map.get(load(cwd), "fail_on", "high")

  @doc "Returns the maximum number of tool calls a single run may make."
  @spec max_tool_calls(String.t()) :: non_neg_integer()
  def max_tool_calls(cwd \\ "."), do: Map.get(load(cwd), "max_tool_calls", 120)

  @doc "Returns the maximum wall-clock seconds a single run may take."
  @spec max_wall_clock_s(String.t()) :: non_neg_integer()
  def max_wall_clock_s(cwd \\ "."), do: Map.get(load(cwd), "max_wall_clock_s", 900)

  @doc "Returns the maximum USD a single run may spend."
  @spec max_cost_usd(String.t()) :: float()
  def max_cost_usd(cwd \\ "."), do: Map.get(load(cwd), "max_cost_usd", 2.0)

  @doc "Returns the maximum total tokens a single run may consume."
  @spec max_tokens(String.t()) :: non_neg_integer()
  def max_tokens(cwd \\ "."), do: Map.get(load(cwd), "max_tokens", 400_000)

  # ---------------------------------------------------------------------
  # Internals
  # ---------------------------------------------------------------------

  # Call sites may pass an already-loaded policy in the context (so a long
  # run reads the file once), otherwise the policy is loaded from the
  # context's `:cwd` (defaulting to the process working directory).
  defp policy_from(%{policy: policy}) when is_map(policy), do: normalize(policy)
  defp policy_from(%{cwd: cwd}) when is_binary(cwd), do: load(cwd)
  defp policy_from(_), do: load(".")

  defp env_policy_path do
    case System.get_env("YOKE_POLICY") do
      path when is_binary(path) and path != "" -> path
      _ -> nil
    end
  end

  defp read_policy_file(path) do
    with true <- File.regular?(path),
         {:ok, content} <- File.read(path),
         {:ok, map} when is_map(map) <- Json.decode(content) do
      map
    else
      _ -> %{}
    end
  end

  defp normalize(policy) when is_map(policy) do
    Enum.reduce(policy, @defaults, fn {key, value}, acc ->
      key = to_string(key)

      case normalize_value(key, value) do
        :drop -> acc
        normalized -> Map.put(acc, key, normalized)
      end
    end)
  end

  defp normalize_value(key, value) when key in ["allow_writes"] and is_boolean(value), do: value

  defp normalize_value(key, value) when key in ["fail_on"] and is_binary(value) do
    case String.downcase(String.trim(value)) do
      severity when severity in ["high", "medium", "low", "info", "never"] -> severity
      _ -> :drop
    end
  end

  defp normalize_value(key, value)
       when key in ["max_tool_calls", "max_wall_clock_s", "max_tokens", "max_diff_bytes"] and
              is_integer(value) and value >= 0,
       do: value

  defp normalize_value("max_cost_usd", value) when is_number(value) and value >= 0,
    do: value * 1.0

  defp normalize_value(_key, value) when is_binary(value) do
    case String.downcase(String.trim(value)) do
      decision when decision in ["approve", "deny"] -> decision
      _ -> :drop
    end
  end

  defp normalize_value(_key, _value), do: :drop
end
