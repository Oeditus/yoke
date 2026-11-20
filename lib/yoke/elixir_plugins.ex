defmodule Yoke.ElixirPlugins do
  @moduledoc """
  Runs Elixir Language Plugins (`oeditus_credo`, `propwise`, `credo`) on diffs
  during code reviews and project audits, with opt-out support.

  Plugins are only invoked when:
    * `cwd` is an Elixir project (`mix.exs` present)
    * not opted out via option (`elixir_plugins: false` / `--no-elixir-plugins`),
      env (`YOKE_ELIXIR_PLUGINS=false`), or config (`"elixir_plugins": false`)
    * the diff contains changed `.ex` / `.exs` files on disk
    * the corresponding plugin dependency is available in `cwd`
  """

  alias Yoke.Audit.Profiles
  alias Yoke.Config
  alias Yoke.Config.CI, as: CIConfig
  alias Yoke.Json

  @plugins ~w(oeditus_credo propwise credo)
  @default_timeout_ms 30_000
  @max_issues_per_tool 25
  @max_propwise_candidates 10

  @doc "Returns the supported Elixir language plugin names in run order."
  @spec plugins() :: [String.t()]
  def plugins, do: @plugins

  @doc "Returns true when `cwd` is an Elixir Mix project."
  @spec elixir_project?(String.t()) :: boolean()
  def elixir_project?(cwd \\ ".") do
    File.regular?(Path.join(cwd, "mix.exs"))
  end

  @doc """
  Returns true unless Elixir language plugins have been opted out via `opts`,
  `YOKE_ELIXIR_PLUGINS`, or `config.json` (`"elixir_plugins": false`).
  """
  @spec enabled?(String.t(), keyword()) :: boolean()
  def enabled?(cwd \\ ".", opts \\ []) do
    case Keyword.get(opts, :elixir_plugins) do
      val when is_boolean(val) ->
        val

      _ ->
        case env_toggle("YOKE_ELIXIR_PLUGINS") do
          val when is_boolean(val) -> val
          nil -> config_enabled?(cwd, opts)
        end
    end
  end

  @doc """
  Returns the subset of `plugins/0` available in `cwd`.

  Checks `deps/<plugin>` when `deps/` exists, or `mix.lock` otherwise, so
  projects that only install a subset of the plugins do not emit missing-task
  noise.
  """
  @spec available_plugins(String.t()) :: [String.t()]
  def available_plugins(cwd \\ ".") do
    deps_dir = Path.join(cwd, "deps")
    has_deps_dir? = File.dir?(deps_dir)
    lock_content = read_if_regular(Path.join(cwd, "mix.lock"))

    Enum.filter(@plugins, fn plugin ->
      cond do
        has_deps_dir? ->
          File.dir?(Path.join(deps_dir, plugin))

        is_binary(lock_content) ->
          String.contains?(lock_content, "\"#{plugin}\"")

        true ->
          false
      end
    end)
  end

  @doc """
  Runs available Elixir language plugins on the diff in `cwd`.

  ## Options
    * `:base_ref` -- git revision to diff against (optional)
    * `:head_ref` -- git revision of the head (optional; when set and not
      matching current `HEAD`, plugins are skipped so we never inspect the
      wrong working tree)
    * `:changed_files` -- list or `MapSet` of changed relative file paths
    * `:elixir_plugins` -- explicit boolean opt-in/opt-out override
    * `:plugins` -- explicit list of plugin names to run
    * `:runner` -- `(tool, args, cwd) -> {output, exit_code}` for tests
    * `:timeout` -- per-plugin timeout in ms (default #{@default_timeout_ms})
    * `:headless` -- read CI config instead of `~/.yoke` (default `false`)
  """
  @spec run_on_diff(String.t(), keyword()) :: {:ok, map()}
  def run_on_diff(cwd \\ ".", opts \\ []) do
    base_ref = Keyword.get(opts, :base_ref)
    head_ref = Keyword.get(opts, :head_ref)

    cond do
      not elixir_project?(cwd) ->
        {:ok, skipped(:not_elixir)}

      not enabled?(cwd, opts) ->
        {:ok, skipped(:opted_out)}

      not head_checked_out?(cwd, head_ref) ->
        {:ok, skipped(:head_not_checked_out)}

      true ->
        do_run_on_diff(cwd, base_ref, opts)
    end
  end

  defp do_run_on_diff(cwd, base_ref, opts) do
    changed_ex_files = resolve_changed_ex_files(cwd, base_ref, Keyword.get(opts, :changed_files))
    plugins = Keyword.get(opts, :plugins) || available_plugins(cwd)

    cond do
      changed_ex_files == [] ->
        {:ok, skipped(:no_elixir_diff_files)}

      plugins == [] ->
        {:ok, skipped(:no_plugins_available)}

      true ->
        runner = Keyword.get(opts, :runner, &default_runner/3)
        timeout = Keyword.get(opts, :timeout, @default_timeout_ms)
        changed_set = MapSet.new(changed_ex_files)

        results =
          plugins
          |> Enum.map(
            &run_plugin(&1, cwd, base_ref, changed_ex_files, changed_set, runner, timeout)
          )
          |> Enum.reject(&is_nil/1)

        {:ok,
         %{
           status: :ok,
           reason: nil,
           base_ref: base_ref,
           changed_files: changed_ex_files,
           results: results
         }}
    end
  end

  @doc """
  Formats a `run_on_diff/2` report into a prompt section for code reviews and
  audits. Returns `""` when skipped or when no plugin produced output.
  """
  @spec format_for_prompt(map() | nil) :: String.t()
  def format_for_prompt(nil), do: ""
  def format_for_prompt(%{status: :skipped}), do: ""
  def format_for_prompt(%{results: []}), do: ""

  def format_for_prompt(%{results: results}) when is_list(results) do
    sections =
      results
      |> Enum.map(&format_plugin_prompt/1)
      |> Enum.reject(&(&1 == ""))

    if sections == [] do
      ""
    else
      """
      ### Elixir Language Plugins (diff)

      #{Enum.join(sections, "\n\n")}
      """
      |> String.trim()
    end
  end

  def format_for_prompt(_), do: ""

  @doc """
  Formats a compact terminal summary line for `Yoke.Audit.format_facts/1`.
  """
  @spec format_summary(map() | nil) :: String.t()
  def format_summary(nil), do: ""
  def format_summary(%{status: :skipped, reason: :opted_out}), do: "opted out"

  def format_summary(%{status: :skipped, reason: :no_elixir_diff_files}),
    do: "no Elixir files in diff"

  def format_summary(%{status: :skipped, reason: :no_plugins_available}),
    do: "no plugins installed"

  def format_summary(%{status: :skipped, reason: :head_not_checked_out}),
    do: "skipped (head not checked out)"

  def format_summary(%{status: :skipped}), do: "skipped"

  def format_summary(%{results: results}) when is_list(results) do
    Enum.map_join(results, " • ", fn
      %{tool: "propwise", status: :ok, total_candidates: count} ->
        "propwise: #{count} candidate(s)"

      %{tool: tool, status: :ok, total_issues: count} ->
        "#{tool}: #{count} issue(s)"

      %{tool: tool, status: :error} ->
        "#{tool}: error"
    end)
  end

  def format_summary(_), do: ""

  # ---------------------------------------------------------------------
  # Plugin execution
  # ---------------------------------------------------------------------

  defp run_plugin("propwise", cwd, _base_ref, changed_ex_files, _changed_set, runner, timeout) do
    source_files = Enum.filter(changed_ex_files, &String.ends_with?(&1, ".ex"))

    if source_files == [] do
      nil
    else
      args = ["--files", Enum.join(source_files, ","), "--format", "json", "--no-fail"]

      case invoke_with_timeout("propwise", args, cwd, runner, timeout) do
        {:ok, output} ->
          parse_propwise_json(output)

        {:error, reason} ->
          %{tool: "propwise", status: :error, candidates: [], total_candidates: 0, error: reason}
      end
    end
  end

  defp run_plugin(tool, cwd, base_ref, _changed_ex_files, changed_set, runner, timeout)
       when tool in ["oeditus_credo", "credo"] do
    args =
      if is_binary(base_ref) and String.trim(base_ref) != "",
        do: ["diff", base_ref, "--format=json"],
        else: ["diff", "--format=json"]

    case invoke_with_timeout(tool, args, cwd, runner, timeout) do
      {:ok, output} ->
        parse_credo_diff_json(tool, output, changed_set)

      {:error, reason} ->
        %{tool: tool, status: :error, issues: [], total_issues: 0, error: reason}
    end
  end

  defp invoke_with_timeout(tool, args, cwd, runner, timeout) do
    task = Task.async(fn -> runner.(tool, args, cwd) end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {output, _code}} when is_binary(output) ->
        if crashed?(output) do
          {:error, String.slice(String.trim(output), 0, 500)}
        else
          {:ok, output}
        end

      {:ok, other} ->
        {:error, "Unexpected runner result: #{inspect(other)}"}

      nil ->
        {:error, "`#{tool}` timed out after #{timeout}ms"}

      {:exit, reason} ->
        {:error, "`#{tool}` crashed: #{inspect(reason)}"}
    end
  rescue
    e -> {:error, "`#{tool}` failed: #{Exception.message(e)}"}
  end

  defp default_runner(tool, args, cwd) do
    System.cmd("mix", [tool | args], cd: cwd, stderr_to_stdout: true)
  end

  defp crashed?(output) do
    String.contains?(output, "** (Mix) The task ") or
      String.contains?(output, "** (Mix) Could not") or
      String.contains?(output, "** (CompileError)")
  end

  # ---------------------------------------------------------------------
  # Parsing
  # ---------------------------------------------------------------------

  defp parse_credo_diff_json(tool, output, changed_set) do
    case decode_json_payload(output) do
      {:ok, %{"diff" => %{"new" => issues}}} when is_list(issues) ->
        build_credo_result(tool, issues, changed_set)

      {:ok, %{"issues" => issues}} when is_list(issues) ->
        build_credo_result(tool, issues, changed_set)

      _ ->
        %{tool: tool, status: :ok, issues: [], total_issues: 0, error: nil}
    end
  end

  defp build_credo_result(tool, issues, changed_set) do
    filtered =
      issues
      |> Enum.map(&normalize_credo_issue/1)
      |> Enum.filter(fn issue ->
        is_binary(issue.file) and MapSet.member?(changed_set, issue.file)
      end)
      |> Enum.sort_by(&(-(&1.priority || 0)))

    %{
      tool: tool,
      status: :ok,
      issues: Enum.take(filtered, @max_issues_per_tool),
      total_issues: length(filtered),
      error: nil
    }
  end

  defp normalize_credo_issue(issue) do
    %{
      file: normalize_path(issue["filename"]),
      line: issue["line_no"],
      priority: issue["priority"],
      check: issue["check"],
      message: to_string(issue["message"] || "")
    }
  end

  defp parse_propwise_json(output) do
    case decode_json_payload(output) do
      {:ok, %{"candidates" => candidates}} when is_list(candidates) ->
        normalized =
          candidates
          |> Enum.map(&normalize_propwise_candidate/1)
          |> Enum.sort_by(&(-(&1.score || 0)))

        %{
          tool: "propwise",
          status: :ok,
          candidates: Enum.take(normalized, @max_propwise_candidates),
          total_candidates: length(normalized),
          error: nil
        }

      _ ->
        %{tool: "propwise", status: :ok, candidates: [], total_candidates: 0, error: nil}
    end
  end

  defp normalize_propwise_candidate(c) do
    %{
      module: c["module"],
      name: c["name"],
      arity: c["arity"],
      file: normalize_path(c["file"]),
      line: c["line"],
      score: c["score"],
      purity: c["purity"],
      laws: List.wrap(c["laws"]),
      patterns: Enum.map(List.wrap(c["patterns"]), &(&1["reason"] || &1["type"])),
      suggestions: List.wrap(c["suggestions"])
    }
  end

  defp decode_json_payload(output) when is_binary(output) do
    case :binary.match(output, "{") do
      {pos, _} ->
        json_slice = binary_part(output, pos, byte_size(output) - pos)

        case Json.decode(json_slice) do
          {:ok, %{} = map} -> {:ok, map}
          _ -> :error
        end

      :nomatch ->
        :error
    end
  end

  # ---------------------------------------------------------------------
  # Prompt formatting
  # ---------------------------------------------------------------------

  defp format_plugin_prompt(%{tool: "propwise", status: :ok, candidates: []}) do
    "**`propwise`**: No property-based testing candidates found on changed Elixir files."
  end

  defp format_plugin_prompt(%{
         tool: "propwise",
         status: :ok,
         candidates: candidates,
         total_candidates: total
       }) do
    header =
      "**`propwise` (#{total} property-based testing candidate(s) on changed files):**\n" <>
        "Present applicable `propwise` suggestions as **actual test improvements** " <>
        "(concrete `ExUnit` / `ExUnitProperties` `property` tests targeting the corresponding " <>
        "`*_test.exs` file, adapted to the function's real types and edge cases)."

    body =
      Enum.map_join(candidates, "\n\n", fn c ->
        test_file = Profiles.expected_test_path(c.file || "", :elixir)
        test_target = if test_file, do: " (suggested test file: `#{test_file}`)", else: ""
        laws_str = if c.laws != [], do: " | laws: #{Enum.join(c.laws, ", ")}", else: ""

        patterns_str =
          if c.patterns != [], do: " | patterns: #{Enum.join(c.patterns, ", ")}", else: ""

        suggestions_block =
          case c.suggestions do
            [] ->
              ""

            list ->
              code = Enum.join(list, "\n\n")
              "\n```elixir\n#{code}\n```"
          end

        "- `#{c.module}.#{c.name}/#{c.arity}` at `#{c.file}:#{c.line}` " <>
          "(score: #{c.score}, purity: #{c.purity}#{laws_str}#{patterns_str})#{test_target}#{suggestions_block}"
      end)

    header <> "\n\n" <> body
  end

  defp format_plugin_prompt(%{tool: tool, status: :ok, issues: []}) do
    "**`#{tool}`**: No new issues on changed files."
  end

  defp format_plugin_prompt(%{tool: tool, status: :ok, issues: issues, total_issues: total}) do
    shown = length(issues)

    header =
      if total > shown,
        do: "**`#{tool}` (showing top #{shown} of #{total} new issue(s) on changed files):**",
        else: "**`#{tool}` (#{total} new issue(s) on changed files):**"

    rows =
      Enum.map_join(issues, "\n", fn issue ->
        loc = if issue.line, do: "#{issue.file}:#{issue.line}", else: issue.file
        check = if issue.check, do: " (`#{issue.check}`)", else: ""
        "- `#{loc}` [priority #{issue.priority || "?"}]#{check}: #{issue.message}"
      end)

    header <> "\n" <> rows
  end

  defp format_plugin_prompt(%{tool: tool, status: :error, error: reason}) do
    "**`#{tool}`**: Could not run (#{reason})."
  end

  # ---------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------

  defp skipped(reason), do: %{status: :skipped, reason: reason, results: []}

  defp config_enabled?(cwd, opts) do
    cfg =
      if Keyword.get(opts, :headless, false) or CIConfig.ci?() do
        CIConfig.load_ci_config(cwd)
      else
        Config.load_config(cwd)
      end

    case Map.get(cfg, "elixir_plugins") do
      val when is_boolean(val) -> val
      _ -> true
    end
  end

  defp env_toggle(var) do
    case System.get_env(var) do
      nil ->
        nil

      val ->
        case String.downcase(String.trim(val)) do
          v when v in ["false", "0", "no", "off"] -> false
          v when v in ["true", "1", "yes", "on"] -> true
          _ -> nil
        end
    end
  end

  defp head_checked_out?(_cwd, nil), do: true
  defp head_checked_out?(_cwd, "HEAD"), do: true

  defp head_checked_out?(cwd, head_ref) when is_binary(head_ref) do
    case Yoke.Git.resolve_revision("HEAD", cwd) do
      {:ok, current_head} ->
        current_head == head_ref or String.starts_with?(current_head, head_ref)

      _ ->
        false
    end
  end

  defp resolve_changed_ex_files(cwd, base_ref, nil) do
    git_args =
      if is_binary(base_ref) and String.trim(base_ref) != "",
        do: ["diff", "--name-only", base_ref],
        else: ["diff", "--name-only", "HEAD"]

    case System.cmd("git", git_args, cd: cwd, stderr_to_stdout: true) do
      {output, 0} ->
        output
        |> String.split("\n", trim: true)
        |> filter_existing_ex_files(cwd)

      _ ->
        []
    end
  rescue
    _ -> []
  end

  defp resolve_changed_ex_files(cwd, _base_ref, files) do
    files
    |> Enum.to_list()
    |> filter_existing_ex_files(cwd)
  end

  defp filter_existing_ex_files(paths, cwd) do
    paths
    |> Enum.map(&normalize_path/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.filter(fn path ->
      (String.ends_with?(path, ".ex") or String.ends_with?(path, ".exs")) and
        File.regular?(Path.join(cwd, path))
    end)
    |> Enum.uniq()
  end

  defp normalize_path(nil), do: nil

  defp normalize_path(path) when is_binary(path) do
    path |> String.trim() |> String.trim_leading("./")
  end

  defp read_if_regular(path) do
    if File.regular?(path), do: File.read!(path), else: nil
  rescue
    _ -> nil
  end
end
