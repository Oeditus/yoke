defmodule Yoke.Aliases do
  @moduledoc """
  Manages session command aliases.
  Aliases allow users to define reusable command sequences (slash commands,
  shell commands, or LLM agent prompts) that execute sequentially within
  the current active session.

  Aliases can be declared in:
    1. Workspace `.yoke/aliases.json` (or `.yoke/config.json` under `"aliases"`)
    2. Global `~/.yoke/aliases.json` (or `~/.yoke/config.json` under `"aliases"`)

  Workspace aliases take precedence over global aliases with the same name.
  """

  @default_aliases %{
    "finish" => %{
      "name" => "finish",
      "description" =>
        "Commit staged changes and create structured PR (includes Reason, Implementation, Verification, Risk, Guidance; supports --commit-only)",
      "commands" => [
        "{{#if_args}}!git add {{args}}{{/if_args}}",
        """
        Please inspect the staged git changes (`git diff --cached`). First run `mix format` if applicable to ensure clean code formatting. Then create a git commit with a comprehensive commit message explicitly structured into the following sections:
        - **The PR reason**: Why this change is made and what issue or motivation drives it.
        - **Implementation**: Architectural details, key design decisions, and components modified.
        - **How to verify**: Exact test commands executed or reproduction steps to verify functionality.
        - **Risk & rollout**: Blast radius, potential risks, dependencies, or rollback instructions.
        - **Reviewer guidance**: Specific areas, critical files, or subtle logic where reviewer attention is needed.
        {{#if_commit_only}}Commit the changes with this message only; do not open a pull request.{{/if_commit_only}}{{#unless_commit_only}}After committing, create a GitHub pull request using `gh pr create` with the title matching the commit summary line and the body containing the exact same structured sections.{{/unless_commit_only}}
        """
      ]
    },
    "pr" => %{
      "name" => "pr",
      "description" =>
        "Alias for /finish (creates commit & PR with structured sections, or commit only with --commit-only)",
      "commands" => [
        "/finish {{args}}{{#if_commit_only}} --commit-only{{/if_commit_only}}"
      ]
    },
    "commit-structured" => %{
      "name" => "commit-structured",
      "description" =>
        "Commit staged changes with comprehensive PR-style structure (no PR created)",
      "commands" => [
        "{{#if_args}}!git add {{args}}{{/if_args}}",
        """
        Please inspect the staged git changes (`git diff --cached`). First run `mix format` if applicable to ensure clean code formatting. Then create a git commit with a comprehensive commit message explicitly structured into the following sections:
        - **The PR reason**: Why this change is made and what issue or motivation drives it.
        - **Implementation**: Architectural details, key design decisions, and components modified.
        - **How to verify**: Exact test commands executed or reproduction steps to verify functionality.
        - **Risk & rollout**: Blast radius, potential risks, dependencies, or rollback instructions.
        - **Reviewer guidance**: Specific areas, critical files, or subtle logic where reviewer attention is needed.
        """
      ]
    },
    "cpr" => %{
      "name" => "cpr",
      "description" => "Alias for /commit-structured",
      "commands" => [
        "/commit-structured {{args}}"
      ]
    }
  }

  @doc "Returns default aliases map."
  def default_aliases, do: @default_aliases

  @doc "Returns path to local project aliases JSON file."
  def aliases_file_path(cwd \\ ".") do
    Path.join([cwd, ".yoke", "aliases.json"])
  end

  @doc "Returns path to global aliases JSON file."
  def global_aliases_file_path do
    Path.expand("~/.yoke/aliases.json")
  end

  @doc "Returns list of all available alias names."
  def list_alias_names(cwd \\ ".") do
    load_aliases(cwd) |> Map.keys() |> Enum.sort()
  end

  @doc "Finds a single alias definition by name."
  def get_alias(name, cwd \\ ".") when is_binary(name) do
    aliases = load_aliases(cwd)

    case Map.get(aliases, name) do
      nil -> :error
      alias_def -> {:ok, alias_def}
    end
  end

  @doc """
  Loads all aliases from disk:
  1. Global config `~/.yoke/config.json` ("aliases")
  2. Global file `~/.yoke/aliases.json`
  3. Local config `.yoke/config.json` ("aliases")
  4. Local file `.yoke/aliases.json`
  5. Built-in defaults if no aliases are defined in local or global files.
  """
  def load_aliases(cwd \\ ".") do
    global_cfg_path = Path.expand("~/.yoke/config.json")
    global_file_path = global_aliases_file_path()
    local_cfg_path = Path.join(cwd, ".yoke/config.json")
    local_file_path = aliases_file_path(cwd)

    global_cfg_aliases = read_config_aliases(global_cfg_path, :global)
    global_file_aliases = read_aliases_file(global_file_path, :global)
    local_cfg_aliases = read_config_aliases(local_cfg_path, :project)
    local_file_aliases = read_aliases_file(local_file_path, :project)

    merged =
      @default_aliases
      |> Map.merge(global_cfg_aliases)
      |> Map.merge(global_file_aliases)
      |> Map.merge(local_cfg_aliases)
      |> Map.merge(local_file_aliases)

    # If the local aliases file does not exist yet, initialize it with defaults
    if not File.exists?(local_file_path) and not File.exists?(Path.dirname(local_file_path)) do
      :ok
    else
      if not File.exists?(local_file_path) and File.dir?(Path.dirname(local_file_path)) do
        # Initialize default aliases in workspace .yoke/aliases.json
        save_all_aliases(@default_aliases, cwd)
      end
    end

    merged
  end

  @doc "Saves a single alias definition into local `.yoke/aliases.json`."
  def save_alias(alias_def, cwd \\ ".") when is_map(alias_def) do
    name = alias_def["name"] || alias_def[:name]

    if is_nil(name) or name == "" do
      {:error, "Alias must have a non-empty 'name'"}
    else
      normalized = normalize_alias(to_string(name), alias_def, :project)
      current = read_raw_aliases_file(aliases_file_path(cwd))
      updated = Map.put(current, to_string(name), normalized)
      save_all_aliases(updated, cwd)
    end
  end

  @doc "Deletes an alias from local `.yoke/aliases.json`."
  def delete_alias(name, cwd \\ ".") when is_binary(name) do
    current = read_raw_aliases_file(aliases_file_path(cwd))

    if Map.has_key?(current, name) do
      updated = Map.delete(current, name)
      save_all_aliases(updated, cwd)
      {:ok, name}
    else
      {:error, "Alias '#{name}' not found in #{aliases_file_path(cwd)}"}
    end
  end

  @doc """
  Expands an alias with user-supplied arguments, returning `{:ok, [commands]}`.
  Each command is interpolated and stripped of leading/trailing whitespace.
  Empty commands (e.g. conditional commands that evaluated to nothing) are omitted.
  """
  def expand_alias(alias_def, raw_args \\ "") when is_map(alias_def) do
    raw_commands =
      cond do
        is_list(alias_def["commands"]) -> alias_def["commands"]
        is_list(alias_def[:commands]) -> alias_def[:commands]
        is_binary(alias_def["command"]) -> [alias_def["command"]]
        is_binary(alias_def[:command]) -> [alias_def[:command]]
        is_binary(alias_def["commands"]) -> [alias_def["commands"]]
        true -> []
      end

    interpolated =
      raw_commands
      |> Enum.map(&interpolate(&1, raw_args))
      |> Enum.reject(&(&1 == ""))

    {:ok, interpolated}
  end

  @commit_flags ["--commit-only", "-c", "--commit"]

  @doc """
  Interpolates argument parameters, flags, and conditionals into a single command string.
  """
  def interpolate(template, raw_args) when is_binary(template) and is_binary(raw_args) do
    raw_args = String.trim(raw_args)
    tokens = String.split(raw_args, ~r/\s+/, trim: true)

    commit_only? = Enum.any?(tokens, &(&1 in @commit_flags))
    clean_tokens = Enum.reject(tokens, &(&1 in @commit_flags))
    clean_args = Enum.join(clean_tokens, " ")
    has_args? = clean_args != ""

    text = template

    # Conditionals: {{#if_args}}...{{/if_args}} and {{#if args}}...{{/if}}
    text =
      Regex.replace(~r/\{\{#if_args\}\}(.*?)\{\{\/if_args\}\}/s, text, fn _, content ->
        if has_args?, do: content, else: ""
      end)

    text =
      Regex.replace(~r/\{\{#if\s+args\}\}(.*?)\{\{\/if\}\}/s, text, fn _, content ->
        if has_args?, do: content, else: ""
      end)

    text =
      Regex.replace(~r/\{\{#unless_args\}\}(.*?)\{\{\/unless_args\}\}/s, text, fn _, content ->
        if has_args?, do: "", else: content
      end)

    text =
      Regex.replace(~r/\{\{#unless\s+args\}\}(.*?)\{\{\/unless\}\}/s, text, fn _, content ->
        if has_args?, do: "", else: content
      end)

    # Conditionals: {{#if_commit_only}}...{{/if_commit_only}} and {{#if commit_only}}...{{/if}}
    text =
      Regex.replace(
        ~r/\{\{#if_commit_only\}\}(.*?)\{\{\/if_commit_only\}\}/s,
        text,
        fn _, content ->
          if commit_only?, do: content, else: ""
        end
      )

    text =
      Regex.replace(~r/\{\{#if\s+commit_only\}\}(.*?)\{\{\/if\}\}/s, text, fn _, content ->
        if commit_only?, do: content, else: ""
      end)

    text =
      Regex.replace(
        ~r/\{\{#unless_commit_only\}\}(.*?)\{\{\/unless_commit_only\}\}/s,
        text,
        fn _, content ->
          if commit_only?, do: "", else: content
        end
      )

    text =
      Regex.replace(~r/\{\{#unless\s+commit_only\}\}(.*?)\{\{\/unless\}\}/s, text, fn _,
                                                                                      content ->
        if commit_only?, do: "", else: content
      end)

    # Positional replacements: $1..$9 and {{arg1}}..{{arg9}}
    text =
      Regex.replace(~r/\$([1-9])/, text, fn _, n ->
        idx = String.to_integer(n) - 1
        Enum.at(clean_tokens, idx, "")
      end)

    text =
      Regex.replace(~r/\{\{arg([1-9])\}\}/, text, fn _, n ->
        idx = String.to_integer(n) - 1
        Enum.at(clean_tokens, idx, "")
      end)

    # Full argument replacements: {{args}}, $@, $*
    has_variable_placeholder? =
      String.contains?(text, ["{{args}}", "$@", "$*"])

    text = String.replace(text, ["{{args}}", "$@", "$*"], clean_args)

    # Automatic append if no placeholders were in the original template and arguments were supplied
    text =
      if has_args? and not has_variable_placeholder? and
           not Regex.match?(~r/(\{\{|\$[@\*0-9])/, template) do
        if String.starts_with?(text, "!") or String.starts_with?(text, "/") do
          text <> " " <> clean_args
        else
          text <> "\n\nSpecified target(s): " <> clean_args
        end
      else
        text
      end

    String.trim(text)
  end

  def interpolate(other, _), do: to_string(other) |> String.trim()

  # ---------------------------------------------------------------------------
  # Persistence & Parsing Helpers
  # ---------------------------------------------------------------------------

  defp save_all_aliases(aliases_map, cwd) do
    file_path = aliases_file_path(cwd)
    dir = Path.dirname(file_path)

    with :ok <- File.mkdir_p(dir),
         {:ok, json} <- Yoke.Json.encode(aliases_map, pretty: true),
         :ok <- File.write(file_path, json) do
      {:ok, file_path}
    else
      err -> {:error, "Failed to save aliases to #{file_path}: #{inspect(err)}"}
    end
  end

  defp read_config_aliases(path, scope) do
    if File.exists?(path) do
      case File.read(path) do
        {:ok, content} ->
          case Yoke.Json.decode(content) do
            {:ok, %{"aliases" => aliases}} -> parse_raw_aliases(aliases, scope)
            _ -> %{}
          end

        _ ->
          %{}
      end
    else
      %{}
    end
  end

  defp read_aliases_file(path, scope) do
    if File.exists?(path) do
      case File.read(path) do
        {:ok, content} ->
          case Yoke.Json.decode(content) do
            {:ok, parsed} -> parse_raw_aliases(parsed, scope)
            _ -> %{}
          end

        _ ->
          %{}
      end
    else
      %{}
    end
  end

  defp read_raw_aliases_file(path) do
    if File.exists?(path) do
      case File.read(path) do
        {:ok, content} ->
          case Yoke.Json.decode(content) do
            {:ok, map} when is_map(map) -> map
            {:ok, list} when is_list(list) -> parse_raw_aliases(list, :project)
            _ -> %{}
          end

        _ ->
          %{}
      end
    else
      %{}
    end
  end

  defp parse_raw_aliases(raw, scope) when is_map(raw) do
    Enum.reduce(raw, %{}, fn {k, v}, acc ->
      name = to_string(k)
      Map.put(acc, name, normalize_alias(name, v, scope))
    end)
  end

  defp parse_raw_aliases(raw, scope) when is_list(raw) do
    Enum.reduce(raw, %{}, fn item, acc ->
      case item do
        %{"name" => name} = map when is_binary(name) and name != "" ->
          Map.put(acc, name, normalize_alias(name, map, scope))

        %{name: name} = map when is_binary(name) and name != "" ->
          Map.put(acc, name, normalize_alias(name, map, scope))

        _ ->
          acc
      end
    end)
  end

  defp parse_raw_aliases(_, _scope), do: %{}

  defp normalize_alias(name, val, scope) when is_binary(val) do
    %{
      "name" => name,
      "description" => "Alias for #{val}",
      "commands" => [val],
      "scope" => scope
    }
  end

  defp normalize_alias(name, val, scope) when is_list(val) do
    %{
      "name" => name,
      "description" => "Alias for #{name}",
      "commands" => Enum.map(val, &to_string/1),
      "scope" => scope
    }
  end

  defp normalize_alias(name, val, scope) when is_map(val) do
    commands =
      cond do
        is_list(val["commands"]) -> val["commands"]
        is_binary(val["command"]) -> [val["command"]]
        is_binary(val["commands"]) -> [val["commands"]]
        true -> []
      end

    %{
      "name" => name,
      "description" => val["description"] || "Alias for #{name}",
      "commands" => commands,
      "scope" => val["scope"] || scope
    }
  end

  defp normalize_alias(name, _, scope) do
    %{
      "name" => name,
      "description" => "Alias for #{name}",
      "commands" => [],
      "scope" => scope
    }
  end
end
