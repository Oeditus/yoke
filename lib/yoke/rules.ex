defmodule Yoke.Rules do
  @moduledoc """
  Rule Engine for Yoke.
  Manages persistent scoped prompt preamble rules (all, cr, commit, etc.).
  """
  require Logger

  @default_rules [
    %{
      "id" => 1,
      "scope" => "all",
      "text" => "typographic quotes “” mean the exact quote",
      "enabled" => true
    },
    %{
      "id" => 2,
      "scope" => "all",
      "text" => "backticks mean a code quote",
      "enabled" => true
    },
    %{
      "id" => 3,
      "scope" => "all",
      "text" =>
        "ALWAYS call dedicated tools and Ragex MCP tools (mcp_ragex_grep, mcp_ragex_symbol_definition, mcp_ragex_symbol_references, mcp_ragex_metaast_search, mcp_ragex_structure, mcp_ragex_view) instead of plain bash whenever possible. Plain bash is strictly a fallback for build/test execution or commands without tool equivalents. Never use raw bash shell commands (grep, sed, find, cat, head) for code exploration, symbol finding, or code analysis",
      "enabled" => true
    },
    %{
      "id" => 4,
      "scope" => "cr",
      "text" => "format table cells multiline to fit in 80 symbols width",
      "enabled" => true
    }
  ]

  @doc "Returns the path to local project rules JSON file."
  def rules_file_path(cwd \\ ".") do
    Path.join([cwd, ".yoke", "rules.json"])
  end

  @doc "Loads rules from disk, initializing defaults if rules.json does not exist."
  def load_rules(cwd \\ ".") do
    file_path = rules_file_path(cwd)

    if File.exists?(file_path) do
      case File.read(file_path) do
        {:ok, content} ->
          case Yoke.Json.decode(content) do
            {:ok, rules} when is_list(rules) -> rules
            _ -> @default_rules
          end

        _ ->
          @default_rules
      end
    else
      save_rules(@default_rules, cwd)
      @default_rules
    end
  end

  @doc "Saves rules to local .yoke/rules.json file."
  def save_rules(rules, cwd \\ ".") when is_list(rules) do
    file_path = rules_file_path(cwd)
    file_path |> Path.dirname() |> File.mkdir_p!()

    case Yoke.Json.encode(rules, pretty: true) do
      {:ok, json} ->
        File.write(file_path, json)
        {:ok, file_path}

      {:error, err} ->
        Logger.warning("[Rules] Failed to encode rules: #{inspect(err)}")
        {:error, err}
    end
  end

  @doc "Parses and adds a new rule string like 'all: text' or 'cr: text' or 'text'."
  def add_rule(raw_input, cwd \\ ".") when is_binary(raw_input) do
    input = String.trim(raw_input)

    {scope, text} =
      case String.split(input, ":", parts: 2) do
        [s, t] when s in ["all", "cr", "review", "commit", "refactor", "test"] ->
          {String.trim(s), String.trim(t)}

        _ ->
          {"all", input}
      end

    insert_rule(scope, text, cwd)
  end

  @doc """
  Adds a rule directly under an arbitrary `scope`, bypassing `add_rule/2`'s
  fixed `all|cr|review|commit|refactor|test` prefix whitelist. Intended for
  programmatic callers (e.g. `Yoke.Workflow.Definition` seeding a
  workflow's own `rules_scope`) rather than the interactive `/rules add`
  command, which should keep validating against the known scope list.
  """
  def add_scoped_rule(scope, text, cwd \\ ".") when is_binary(scope) and is_binary(text) do
    insert_rule(scope, text, cwd)
  end

  defp insert_rule(scope, text, cwd) do
    text = String.trim(text)

    if text == "" do
      {:error, "Rule text cannot be empty."}
    else
      rules = load_rules(cwd)
      max_id = Enum.map(rules, &Map.get(&1, "id", 0)) |> Enum.max(fn -> 0 end)

      new_rule = %{
        "id" => max_id + 1,
        "scope" => scope,
        "text" => text,
        "enabled" => true
      }

      updated_rules = rules ++ [new_rule]
      save_rules(updated_rules, cwd)
      {:ok, new_rule}
    end
  end

  @doc "Deletes rules matching given ID array."
  def delete_rules(ids, cwd \\ ".") when is_list(ids) do
    rules = load_rules(cwd)
    id_set = MapSet.new(Enum.map(ids, &to_integer/1))

    updated = Enum.reject(rules, fn r -> MapSet.member?(id_set, Map.get(r, "id")) end)
    save_rules(updated, cwd)
    {:ok, updated}
  end

  @doc "Toggles rule enabled status by ID."
  def toggle_rule(id, cwd \\ ".") do
    target_id = to_integer(id)
    rules = load_rules(cwd)

    if Enum.any?(rules, fn r -> Map.get(r, "id") == target_id end) do
      updated =
        Enum.map(rules, fn r ->
          if Map.get(r, "id") == target_id do
            Map.put(r, "enabled", not Map.get(r, "enabled", true))
          else
            r
          end
        end)

      save_rules(updated, cwd)
      {:ok, updated}
    else
      {:error, "Rule ##{id} not found."}
    end
  end

  @doc "Builds prompt preamble text for a given command context (e.g. 'cr', 'all', or nil)."
  def build_preamble(cmd_context \\ nil, cwd \\ ".") do
    rules = load_rules(cwd)
    ctx = if cmd_context, do: to_string(cmd_context), else: nil

    applicable =
      Enum.filter(rules, fn r ->
        Map.get(r, "enabled", true) and
          (Map.get(r, "scope") == "all" or Map.get(r, "scope") == ctx)
      end)

    rules_text =
      if Enum.empty?(applicable) do
        ""
      else
        rule_lines =
          Enum.map_join(applicable, "\n", fn r ->
            "- #{Map.get(r, "text")}"
          end)

        "=== Prompt & Execution Rules ===\n\n#{rule_lines}\n\n===============================\n\n"
      end

    practices_text = Yoke.Practices.build_preamble(cwd)
    lessons_text = Yoke.Lessons.build_preamble(cwd)

    parts = Enum.reject([rules_text, practices_text, lessons_text], &(&1 == ""))
    Enum.join(parts, "\n\n")
  end

  defp to_integer(i) when is_integer(i), do: i

  defp to_integer(s) when is_binary(s) do
    case Integer.parse(String.trim(s)) do
      {num, _} -> num
      _ -> 0
    end
  end

  defp to_integer(_), do: 0
end
