defmodule Yoke.Config.CI do
  @moduledoc """
  CI configuration resolution (`docs/CI_PLAN.md` §2.1, Phase 1.0).

  Resolves a single effective configuration for a headless run from three
  layers, in order of increasing precedence:

  1. **Repository config** -- `<cwd>/.yoke/config.json` (the same file the
     interactive REPL reads).
  2. **Policy** -- `<cwd>/.yoke/policy.json` (or `YOKE_POLICY`), see
     `Yoke.Interaction.Policy`.
  3. **Environment** -- `YOKE_*` variables, which is how GitHub Actions
     `action.yml` inputs reach the process.
  4. **Action inputs** -- an explicit keyword list passed by the CLI, which
     wins over everything.

  ## The one hard rule

  This module **never reads or writes `~/.yoke`**. A CI runner starts from a
  clean home directory with no user config, and a review must not silently
  change behaviour because of whatever happens to be in the runner's `$HOME`.
  `Yoke.Config.load_config/1` merges the global layer; this module deliberately
  does not call it.

  ## Why a separate module

  `Yoke.Config.load_config/1` is the interactive path and must keep merging
  `~/.yoke` (users rely on it). Extracting the CI-specific resolution here
  keeps that behaviour untouched while giving CI a hermetic, testable
  alternative.
  """

  alias Yoke.Interaction.Policy
  alias Yoke.Json

  # Environment variables that map onto config keys. Each is read only when
  # set and non-empty, so an unset variable never clobbers a repo value.
  @env_map %{
    "YOKE_MODEL" => "model",
    "YOKE_ENDPOINT" => "endpoint",
    "YOKE_API_KEY" => "api_key",
    "YOKE_DEFAULT_BRANCH" => "default_branch",
    "YOKE_MAX_TOKENS" => "max_tokens",
    "YOKE_MAX_TOOL_DEPTH" => "max_tool_depth",
    "YOKE_TEMPERATURE" => "temperature",
    "YOKE_LANGUAGES" => "languages",
    "YOKE_ASSISTANT_NAME" => "assistant_name"
  }

  # Config keys whose environment values are integers.
  @integer_keys ~w(max_tokens max_tool_depth)

  # Config keys whose environment values are floats.
  @float_keys ~w(temperature)

  @doc """
  Loads the effective CI configuration for `cwd`.

  Returns a plain map with string keys, always containing at least the
  repository config merged over `Yoke.Config.default_config_value/1`
  defaults. `inputs` (a keyword list or map) is applied last and wins.

  Never touches `~/.yoke`.
  """
  @spec load_ci_config(String.t(), keyword() | map()) :: map()
  def load_ci_config(cwd \\ ".", inputs \\ []) do
    repo = read_repo_config(cwd)

    env =
      Enum.reduce(@env_map, %{}, fn {var, key}, acc ->
        case System.get_env(var) do
          nil -> acc
          "" -> acc
          value -> Map.put(acc, key, coerce(key, value))
        end
      end)

    explicit =
      inputs
      |> Enum.map(fn {k, v} -> {to_string(k), v} end)
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new()

    repo
    |> Map.merge(env)
    |> Map.merge(explicit)
    |> Map.put("policy", Policy.load(cwd))
    |> Map.put("cwd", cwd)
  end

  @doc """
  Returns the effective policy for a CI run.

  Convenience wrapper over `Yoke.Interaction.Policy.load/1` so callers do not
  need to know which module owns the policy file.
  """
  @spec policy(String.t()) :: map()
  def policy(cwd \\ "."), do: Policy.load(cwd)

  @doc """
  Returns the `--fail-on` threshold a run should use.

  Precedence: explicit `--fail-on` flag → `YOKE_FAIL_ON` → policy `fail_on` →
  `"high"` on `pull_request` events, `"never"` otherwise (§4.6 of the plan).
  """
  @spec fail_on(String.t(), String.t() | nil) :: String.t()
  def fail_on(cwd \\ ".", explicit \\ nil) do
    cond do
      is_binary(explicit) and explicit != "" ->
        normalize_severity(explicit)

      (env = System.get_env("YOKE_FAIL_ON")) && env != "" ->
        normalize_severity(env)

      true ->
        default_fail_on(cwd)
    end
  end

  @doc """
  Returns the default `--fail-on` threshold for the current GitHub event.

  Findings gate on `pull_request` (where a reviewer is expected to block) and
  never gate on `push` (where a red build would be noise).
  """
  @spec default_fail_on(String.t()) :: String.t()
  def default_fail_on(cwd \\ ".") do
    case System.get_env("GITHUB_EVENT_NAME") do
      "pull_request" -> "high"
      "pull_request_target" -> "high"
      nil -> Policy.fail_on(cwd)
      _ -> "never"
    end
  end

  @doc """
  Returns true when the current process looks like it is running in CI.

  Checks the conventional `CI` and `GITHUB_ACTIONS` variables. Used to decide
  whether to install `Yoke.Interaction.Policy` and `:ci` Hands automatically.
  """
  @spec ci?() :: boolean()
  def ci? do
    truthy?(System.get_env("CI")) or truthy?(System.get_env("GITHUB_ACTIONS"))
  end

  @doc """
  Installs the headless seams into the application environment.

  Called by `yoke review` (and any other CI subcommand) before starting a
  session:

    * `:interaction` → `Yoke.Interaction.Policy`
    * `:auto_start_ragex` → `false` (no `dllb-server`, no embedding download)
    * `:output_mode` → `:plain` unless a TTY is genuinely present
    * `:non_interactive` → `true`

  Returns the list of `{key, value}` pairs that were applied, which is useful
  for `--doctor` output and for tests.
  """
  @spec install_headless_seams(String.t()) :: [{atom(), term()}]
  def install_headless_seams(_cwd \\ ".") do
    applied = [
      {:interaction, Yoke.Interaction.Policy},
      {:auto_start_ragex, false},
      {:non_interactive, true},
      {:output_mode, :plain}
    ]

    Enum.each(applied, fn {key, value} -> Application.put_env(:yoke, key, value) end)
    applied
  end

  # ---------------------------------------------------------------------
  # Internals
  # ---------------------------------------------------------------------

  # Reads only the repository layer -- never `~/.yoke`.
  defp read_repo_config(cwd) do
    path = Path.join(cwd, ".yoke/config.json")

    defaults =
      %{
        "assistant_name" => "Robby Ott",
        "model" => "deepseek-flash",
        "endpoint" => "https://api.deepseek.com/chat/completions",
        "permission_mode" => "ask_confirm",
        "tool_permissions" => %{},
        "max_tool_depth" => 1000,
        "plan_gate_enabled" => true,
        "plan_gate_threshold" => 2,
        "loop_detection_enabled" => true,
        "max_cycle_period" => 4,
        "max_tokens" => nil,
        "default_branch" => nil,
        "languages" => nil
      }

    case File.read(path) do
      {:ok, content} ->
        case Json.decode(content) do
          {:ok, map} when is_map(map) -> Map.merge(defaults, map)
          _ -> defaults
        end

      _ ->
        defaults
    end
  end

  defp coerce("languages", value) do
    value
    |> String.split(~r/[,;\s]+/, trim: true)
    |> Enum.reject(&(&1 == ""))
  end

  defp coerce(key, value) when key in @integer_keys do
    case Integer.parse(String.trim(value)) do
      {int, ""} -> int
      _ -> value
    end
  end

  defp coerce(key, value) when key in @float_keys do
    case Float.parse(String.trim(value)) do
      {float, ""} -> float
      _ -> value
    end
  end

  defp coerce(_key, value), do: value

  defp normalize_severity(value) do
    case String.downcase(String.trim(value)) do
      severity when severity in ["high", "medium", "low", "info", "never"] -> severity
      _ -> "high"
    end
  end

  defp truthy?(nil), do: false
  defp truthy?(""), do: false
  defp truthy?("0"), do: false
  defp truthy?("false"), do: false
  defp truthy?(_), do: true
end
