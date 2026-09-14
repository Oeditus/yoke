defmodule Yoke.Config do
  @moduledoc """
  Manages persistent configuration (~/.yoke/config.json) and project rules (.yokerules, .yoke/rules.md).
  """

  @default_config %{
    "model" => "deepseek-chat",
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
    "max_tool_depth" => 100,
    # These enforce the built-in "plan -> approve -> execute" gate for
    # non-trivial tasks. The gate is default-ON: once a task requires more
    # than `plan_gate_threshold` modifying tool calls, Yoke pauses to present
    # a plan and require explicit approval before proceeding. Override by
    # adding "plan_gate_enabled": <bool> / "plan_gate_threshold": <n> to
    # .yoke/config.json (or ~/.yoke/config.json).
    "plan_gate_enabled" => true,
    "plan_gate_threshold" => 2,
    # God mode switcher: when enabled, all questions and confirmations are
    # automatically answered without user interaction. Default: false.
    "god_mode" => false
  }

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

  @doc "Loads combined configuration (global + workspace override)."
  def load_config(cwd \\ ".") do
    global_path = Path.expand("~/.yoke/config.json")
    local_path = Path.join(cwd, ".yoke/config.json")

    global_cfg = read_json_config(global_path)
    local_cfg = read_json_config(local_path)

    merged_cfg = Map.merge(global_cfg, local_cfg)

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

  def save_global_config(new_config) do
    global_path = Path.expand("~/.yoke/config.json")

    with :ok <- global_path |> Path.dirname() |> File.mkdir_p(),
         {:ok, json} <- Yoke.Json.encode(new_config, pretty: true),
         :ok <- File.write(global_path, json) do
      {:ok, global_path}
    else
      err -> {:error, "Failed to save config to #{global_path}: #{inspect(err)}"}
    end
  end

  @doc "Saves workspace local configuration file (.yoke/config.json)."
  def save_config(config, cwd \\ ".") do
    local_path = Path.join(cwd, ".yoke/config.json")

    with :ok <- local_path |> Path.dirname() |> File.mkdir_p(),
         {:ok, json} <- Yoke.Json.encode(config, pretty: true),
         :ok <- File.write(local_path, json) do
      :ok
    else
      err -> {:error, "Failed to save local config: #{inspect(err)}"}
    end
  end

  @doc "Persists a per-tool permission policy override in global system config (~/.yoke/config.json)."
  def set_global_tool_permission(tool_name, policy) do
    global_path = Path.expand("~/.yoke/config.json")
    global_cfg = read_json_config(global_path)
    perms = Map.get(global_cfg, "tool_permissions", %{})
    updated_perms = Map.put(perms, tool_name, policy)
    updated_cfg = Map.put(global_cfg, "tool_permissions", updated_perms)
    save_global_config(updated_cfg)
  end

  @doc "Persists a per-tool permission policy override in local workspace config (.yoke/config.json)."
  def set_tool_permission(tool_name, policy, cwd \\ ".") do
    current_cfg = load_config(cwd)
    perms = Map.get(current_cfg, "tool_permissions", %{})
    updated_perms = Map.put(perms, tool_name, policy)
    updated_cfg = Map.put(current_cfg, "tool_permissions", updated_perms)
    save_config(updated_cfg, cwd)
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
