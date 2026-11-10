defmodule Yoke.Config do
  @moduledoc """
  Manages persistent configuration (~/.yoke/config.json) and project rules (.yokerules, .yoke/rules.md).
  """

  @default_config %{
    "assistant_name" => "Robby Ott",
    "model" => "deepseek-flash",
    "endpoint" => "https://api.deepseek.com/chat/completions",
    # "auto_approve" | "ask_confirm"
    "permission_mode" => "ask_confirm",
    # Per-tool overrides: e.g. %{"bash" => "confirm", "read_file" => "allow"}
    "tool_permissions" => %{},
    "sandbox_workspace" => false,
    "temperature" => 0.7,
    "system_prompt_addon" => "",
    "mcp_servers" => %{},
    "prompt_style" => "starship",
    "enable_autosuggestions" => true,
    "enable_syntax_highlighting" => true,
    "enable_context_gauge" => true,
    "enable_file_picker" => true,
    "enable_code_highlighting" => true,
    # Switches the idle status bar's toggleable segment from the token/cost
    # gauge to a compact "id + message count" line (toggle: Ctrl+B or
    # `/config toggle compact_status_bar`).
    "compact_status_bar" => false,
    # Assumed model context window size (tokens) used by the status bar's
    # usage gauge. Override per-workspace if DeepSeek's limits change.
    "max_context_tokens" => 64_000,
    # Maximum number of tokens to request per API completion call (sent as
    # the `max_tokens` field on each DeepSeek chat-completions request). This
    # bounds the length of a single model response. It is configurable so
    # users can tune it per model/provider; set it to `null` to omit the
    # parameter and let the provider apply its own default. Override globally
    # in ~/.yoke/config.json (or per workspace in .yoke/config.json).
    "max_tokens" => nil,
    # Model pricing, expressed as USD per 1,000,000 tokens, used to compute
    # the estimated session cost shown by the status bar gauge, /cost, and
    # /stats. Defaults to DeepSeek's published V3 rates (prompt $0.14/1M,
    # completion $0.28/1M). Override globally in ~/.yoke/config.json (or per
    # workspace in .yoke/config.json) when you use a different model/provider
    # (e.g. deepseek-reasoner or an OpenRouter/SiliconFlow route) so the
    # reported cost reflects your actual per-million price.
    "price_per_million_prompt_tokens" => 0.14,
    "price_per_million_completion_tokens" => 0.28,
    # Maximum number of consecutive tool-calling turns a single agent loop
    # will run before pausing to ask the user whether to continue. Override
    # per-workspace (or globally) by adding "max_tool_depth": <n> to
    # .yoke/config.json (or ~/.yoke/config.json).
    "max_tool_depth" => 1000,
    # These enforce the built-in "plan -> approve -> execute" gate for
    # non-trivial tasks. The gate is default-ON: once a task requires more
    # than `plan_gate_threshold` modifying tool calls, Yoke pauses to present
    # a plan and require explicit approval before proceeding. Override by
    # adding "plan_gate_enabled": <bool> / "plan_gate_threshold": <n> to
    # .yoke/config.json (or ~/.yoke/config.json).
    "plan_gate_enabled" => true,
    "plan_gate_threshold" => 2,
    # Repeating tool loop detection: identifies periodic tool cycles (e.g. A -> B -> A -> B)
    # and automatically injects an interruption directive before wasting turns and tokens.
    "loop_detection_enabled" => true,
    "max_cycle_period" => 4,
    # A tool-free assistant message that only announces the next action
    # ("Let me implement the method now") leaves the requested work undone.
    # When enabled, the harness answers with a short continuation notice and
    # lets the model act instead of returning the unfinished turn to the user.
    # Bounded to two consecutive notices per turn. Disable by adding
    # "narrate_continuation_enabled": false to .yoke/config.json.
    "narrate_continuation_enabled" => true,
    # God mode switcher: when enabled, all questions and confirmations are
    # automatically answered without user interaction. Default: false.
    "god_mode" => false,
    # Reasoning output ANSI color ("yellow", "cyan", "green", "magenta", "blue", "red", "gray", "white", etc.)
    "reasoning_color" => "gray",
    # Default base branch used for code reviews and comparisons (/cr, /review) when not specified.
    # When unset or nil, Yoke probes for "main" first and falls back to "master".
    "default_branch" => nil,
    # Explicit list of programming languages used in the project (e.g. ["elixir"]).
    # When set (non-empty list or string), only practices for these languages are exposed to the model as constraints.
    # When nil or empty, languages are automatically detected from workspace files.
    "languages" => nil,
    # Reusable session command aliases (name => command | commands | definition)
    "aliases" => %{}
  }

  @doc "Returns the configured project languages list or nil if auto-detection should be used."
  def languages(cwd \\ ".") do
    cfg = load_config(cwd)

    case Map.get(cfg, "languages") do
      langs when is_list(langs) ->
        langs
        |> Enum.map(&to_string/1)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))

      lang when is_binary(lang) and lang != "" ->
        [String.trim(lang)]

      _ ->
        nil
    end
  end

  @doc "Returns the configured assistant name, defaulting to 'Robby Ott'."
  def assistant_name(cwd \\ ".") do
    case Application.get_env(:yoke, :assistant_name) do
      name when is_binary(name) and name != "" and name != "Robby Ott" ->
        name

      app_name ->
        cfg = load_config(cwd)

        case Map.get(cfg, "assistant_name") do
          name when is_binary(name) and name != "" and name != "Robby Ott" ->
            name

          _ ->
            if is_binary(app_name) and app_name != "", do: app_name, else: "Robby Ott"
        end
    end
  end

  @doc "Sets the global assistant name."
  def set_assistant_name(name) when is_binary(name) do
    Application.put_env(:yoke, :assistant_name, name)
  end

  @doc "Returns true if God mode is enabled (auto-answering all model questions and confirmations)."
  def god_mode?(cwd \\ ".") do
    case Application.get_env(:yoke, :god_mode) do
      b when is_boolean(b) ->
        b

      _ ->
        if function_exported?(Mix, :env, 0) and Mix.env() == :test do
          true
        else
          cfg = load_config(cwd)
          Map.get(cfg, "god_mode", false) or Map.get(cfg, "god_mode_enabled", false)
        end
    end
  end

  @doc "Returns the configured reasoning color (e.g. 'yellow', 'cyan', 'magenta'). Defaults to 'yellow'."
  def reasoning_color(cwd \\ ".") do
    case Application.get_env(:yoke, :reasoning_color) do
      c when is_binary(c) and c != "" ->
        c

      _ ->
        cfg = load_config(cwd)
        Map.get(cfg, "reasoning_color") || Map.get(cfg, "reasoning_colour") || "gray"
    end
  end

  @doc "Returns the configured default base branch for code reviews and comparisons, or nil if unset."
  def default_branch(cwd \\ ".") do
    case Application.get_env(:yoke, :default_branch) do
      b when is_binary(b) and b != "" ->
        b

      _ ->
        cfg = load_config(cwd)

        case Map.get(cfg, "default_branch") do
          b when is_binary(b) and b != "" -> String.trim(b)
          _ -> nil
        end
    end
  end

  @doc "Sets the default branch in Application env."
  def set_default_branch(branch) when is_binary(branch) do
    Application.put_env(:yoke, :default_branch, branch)
  end

  @doc "Returns the built-in default value for a configuration key."
  def default_config_value(key), do: Map.get(@default_config, key)

  @doc "Reads and decodes a JSON config file, returning `%{}` when absent or malformed."
  def read_json_file(path), do: read_json_config(path)

  @doc "Loads combined configuration (global + workspace override)."
  def load_config(cwd \\ ".") do
    global_cfg = read_json_config(global_config_path())
    local_cfg = read_json_config(local_config_path(cwd))

    merged_cfg = Map.merge(global_cfg, local_cfg)

    # Migrate legacy default model "deepseek-chat" to "deepseek-flash"
    merged_cfg =
      case Map.get(merged_cfg, "model") do
        "deepseek-chat" -> Map.put(merged_cfg, "model", "deepseek-flash")
        _ -> merged_cfg
      end

    global_perms = Map.get(global_cfg, "tool_permissions", %{})
    local_perms = Map.get(local_cfg, "tool_permissions", %{})
    combined_perms = Map.merge(global_perms, local_perms)

    Map.merge(@default_config, merged_cfg)
    |> Map.put("tool_permissions", combined_perms)
  end

  @doc "Discovers project rule files (.yokerules, .yoke/rules.md, .yoke/SYSTEM.md) in current workspace."
  def discover_project_rules(cwd \\ ".") do
    rule_files = [
      Path.join(cwd, ".yokerules"),
      Path.join(cwd, ".yoke/rules.md"),
      Path.join(cwd, ".yoke/SYSTEM.md")
    ]

    file_rules =
      rule_files
      |> Enum.filter(&File.exists?/1)
      |> Enum.map_join("\n", fn path ->
        case File.read(path) do
          {:ok, content} -> "=== Project Rule (#{Path.basename(path)}) ===\n#{content}\n"
          _ -> ""
        end
      end)

    practices = Yoke.Practices.build_preamble(cwd)

    case {file_rules, practices} do
      {"", ""} -> ""
      {r, ""} -> r
      {"", p} -> p
      {r, p} -> r <> "\n" <> p
    end
  end

  @doc """
  Returns the path of the workspace-local config file for `cwd`.

  `cwd` is expanded first: callers that pass `"."` (the common case) must not
  have their writes land in the *process* working directory when it differs
  from the workspace the user is looking at, and an unexpanded relative path
  would make `Path.dirname/1` create `.yoke/` relative to wherever the VM
  happens to be.
  """
  @spec local_config_path(String.t()) :: String.t()
  def local_config_path(cwd \\ ".") do
    Path.join(Path.expand(cwd), ".yoke/config.json")
  end

  @doc "Returns the path of the global config file (`~/.yoke/config.json`)."
  @spec global_config_path() :: String.t()
  def global_config_path, do: Path.expand("~/.yoke/config.json")

  @doc """
  Persists a single key/value pair into the workspace-local config
  (`.yoke/config.json`) and returns `{:ok, path}`.

  Unlike `save_config/2`, this performs a read-modify-write of the *raw file
  on disk* rather than dumping a merged snapshot. That distinction matters:
  `load_config/1` merges `~/.yoke/config.json` into the result, so writing a
  loaded snapshot back into the workspace file silently copies every global
  setting into the project (and freezes it there, shadowing later global
  changes). It also means a concurrent writer's keys are preserved instead of
  being clobbered by a stale in-memory copy.

  Writes are atomic (temp file + rename) and the parent directory is created
  on demand, so a crash mid-write can never leave a truncated config behind.
  """
  @spec put_local(String.t(), term(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def put_local(key, value, cwd \\ ".") when is_binary(key) do
    path = local_config_path(cwd)
    current = read_json_config(path)
    write_json_atomic(path, Map.put(current, key, value))
  end

  @doc """
  Persists a single key/value pair into the global config
  (`~/.yoke/config.json`) and returns `{:ok, path}`.
  """
  @spec put_global(String.t(), term()) :: {:ok, String.t()} | {:error, String.t()}
  def put_global(key, value) when is_binary(key) do
    path = global_config_path()
    current = read_json_config(path)
    write_json_atomic(path, Map.put(current, key, value))
  end

  @doc """
  Writes `config` to `path` atomically: encode, write to a sibling temp file,
  `fsync`, then rename over the target.

  A plain `File.write/2` truncates the destination before writing, so a crash,
  a full disk, or a kill signal in between leaves an empty or half-written
  JSON file — which `load_config/1` then silently treats as `%{}`, i.e. every
  setting the user saved is gone. Rename is atomic on POSIX, so the target is
  either the old file or the complete new one, never a partial.
  """
  @spec write_json_atomic(String.t(), map()) :: {:ok, String.t()} | {:error, String.t()}
  def write_json_atomic(path, config) when is_map(config) do
    tmp = "#{path}.#{System.unique_integer([:positive])}.tmp"

    with :ok <- path |> Path.dirname() |> File.mkdir_p(),
         {:ok, json} <- Yoke.Json.encode(config, pretty: true),
         :ok <- File.write(tmp, json),
         :ok <- fsync(tmp),
         :ok <- File.rename(tmp, path) do
      {:ok, path}
    else
      err ->
        _ = File.rm(tmp)
        {:error, "Failed to save config to #{path}: #{inspect(err)}"}
    end
  end

  defp fsync(path) do
    case File.open(path, [:read, :write, :binary]) do
      {:ok, io} ->
        result = :file.sync(io)
        File.close(io)
        result

      {:error, _} = err ->
        err
    end
  end

  def save_global_config(new_config) do
    global_path = global_config_path()

    case write_json_atomic(global_path, new_config) do
      {:ok, path} -> {:ok, path}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Saves workspace local configuration file (.yoke/config.json)."
  def save_config(config, cwd \\ ".") do
    case write_json_atomic(local_config_path(cwd), config) do
      {:ok, _path} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Persists a per-tool permission policy override in global system config (~/.yoke/config.json)."
  def set_global_tool_permission(tool_name, policy) do
    global_path = global_config_path()
    global_cfg = read_json_config(global_path)
    perms = Map.get(global_cfg, "tool_permissions", %{})
    updated_perms = Map.put(perms, tool_name, policy)
    updated_cfg = Map.put(global_cfg, "tool_permissions", updated_perms)
    save_global_config(updated_cfg)
  end

  @doc """
  Persists a per-tool permission policy override in local workspace config
  (`.yoke/config.json`).

  This is the "Allow/Deny always (save to project config)" path. It used to
  write back a `load_config/1` snapshot — i.e. the whole merged global+local
  config — which both copied global settings into the project file and could
  resurrect stale values. It now patches only the `tool_permissions` map in
  the on-disk file.
  """
  def set_tool_permission(tool_name, policy, cwd \\ ".") do
    path = local_config_path(cwd)
    current_cfg = read_json_config(path)
    perms = Map.get(current_cfg, "tool_permissions", %{})
    updated_perms = Map.put(perms, tool_name, policy)

    case write_json_atomic(path, Map.put(current_cfg, "tool_permissions", updated_perms)) do
      {:ok, _path} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp read_json_config(path) do
    if File.exists?(path) do
      case File.read(path) do
        {:ok, content} ->
          case Yoke.Json.decode(content) do
            {:ok, map} when is_map(map) -> map
            _ -> %{}
          end

        _ ->
          %{}
      end
    else
      %{}
    end
  end
end
