defmodule Yoke.Audit do
  @moduledoc """
  Whole-project audit engine behind the `/audit` REPL command and
  `yoke audit --project`.

  The audit has two halves, deliberately kept separate:

  ## 1. Deterministic facts (this module)

  Cheap, reproducible measurements gathered straight from the workspace — no
  LLM call, no network. They exist so the agent's narrative is *grounded*:
  every claim it makes can be checked against a number produced here.

    * **Shape** — languages, source/test file counts, inline test counts,
      line counts, largest modules, `TODO`/`FIXME`/`HACK` markers.
    * **Hygiene** — language-appropriate formatter/linter/static-analysis
      configuration, CI workflows, lockfiles, docs, license, `.gitignore`,
      and project quality gates.
    * **Health** — test-to-source ratio, sibling test coverage (when the
      language convention defines one), and git working-tree state.

  Language defaults and `.yoke/config.json` `"audit"` overrides are resolved
  by `Yoke.Audit.Profiles`.

  ## 2. Narrative (the agent)

  The facts are rendered into a prompt that asks for four sections: **strong
  parts**, **weaknesses & glitches**, **codebase improvements**, and **UX
  improvements**. The prompt insists on evidence — file paths and numbers —
  and forbids generic advice that would apply to any project.
  """

  alias Yoke.Audit.Profiles
  alias Yoke.CLI.Formatter

  @marker_regex ~r/\b(TODO|FIXME|HACK|XXX|OPTIMIZE)\b/
  @max_modules_listed 15

  @doc """
  Collects deterministic audit facts for the workspace at `cwd`.

  Returns a plain map (no struct) so it renders to JSON trivially and stays
  easy to extend.

  ## Options

    * `:audit_config` — override map (normally read from `.yoke/config.json` `"audit"`).
  """
  @spec collect(String.t(), keyword()) :: map()
  def collect(cwd \\ ".", opts \\ []) do
    detected_languages = safe(fn -> Yoke.Practices.detect_languages(cwd) end, [])
    profile = Profiles.resolve(cwd, detected_languages, opts)

    test_files = glob(cwd, profile.test_globs, cwd, profile.ignore_dirs)
    test_set = MapSet.new(test_files)

    source_files =
      cwd
      |> glob(profile.source_globs, cwd, profile.ignore_dirs)
      |> Enum.reject(&MapSet.member?(test_set, &1))

    health_facts = health(cwd, profile, source_files, test_files)

    elixir_plugins =
      if "elixir" in profile.languages do
        collect_elixir_plugins(cwd, health_facts.base_branch, opts)
      else
        nil
      end

    %{
      cwd: Path.expand(cwd),
      shape: shape(profile, source_files, test_files),
      hygiene: hygiene(cwd, profile),
      health: health_facts,
      markers: markers(cwd, source_files, test_set),
      elixir_plugins: elixir_plugins
    }
  end

  defp collect_elixir_plugins(cwd, base_branch, opts) do
    case Keyword.get(opts, :elixir_plugin_report) do
      %{} = precomputed ->
        precomputed

      nil ->
        diff_base = resolve_audit_diff_base(cwd, base_branch)

        {:ok, report} =
          Yoke.ElixirPlugins.run_on_diff(
            cwd,
            Keyword.merge(
              [base_ref: diff_base],
              Keyword.take(opts, [:elixir_plugins, :plugins, :runner])
            )
          )

        report
    end
  end

  # When on a feature branch ahead of `base_branch`, diff against `base_branch`
  # (which covers both committed branch changes and uncommitted edits). When on
  # `base_branch` itself or when `base_branch` is nil, diff against `HEAD`.
  defp resolve_audit_diff_base(_cwd, nil), do: nil

  defp resolve_audit_diff_base(cwd, base_branch) do
    case System.cmd("git", ["rev-parse", "--abbrev-ref", "HEAD"], cd: cwd, stderr_to_stdout: true) do
      {branch, 0} ->
        if String.trim(branch) == base_branch, do: nil, else: base_branch

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  # ---------------------------------------------------------------------
  # Facts
  # ---------------------------------------------------------------------

  defp shape(profile, source_files, test_files) do
    sizes =
      source_files
      |> Enum.map(fn path -> {path, line_count(path)} end)
      |> Enum.sort_by(fn {_path, lines} -> -lines end)

    %{
      languages: profile.languages,
      source_file_count: length(source_files),
      test_file_count: length(test_files),
      inline_tested_count: count_inline_tested(source_files, profile.inline_test_regexes),
      source_lines: sizes |> Enum.map(&elem(&1, 1)) |> Enum.sum(),
      largest_modules: Enum.take(sizes, @max_modules_listed)
    }
  end

  defp count_inline_tested(_source_files, []), do: 0

  defp count_inline_tested(source_files, regexes) do
    Enum.count(source_files, fn path ->
      case File.read(path) do
        {:ok, content} -> Enum.any?(regexes, &Regex.match?(&1, content))
        _ -> false
      end
    end)
  end

  defp hygiene(cwd, profile) do
    tools =
      Enum.map(profile.tools, fn tool ->
        status =
          cond do
            exists_any?(cwd, tool.files) -> :configured
            tool.builtin -> :builtin
            true -> :missing
          end

        %{key: tool.key, label: tool.label, status: status}
      end)

    %{
      tools: tools,
      has_formatter:
        Enum.any?(tools, &(&1.key == :formatter and &1.status in [:configured, :builtin])),
      has_ci: exists_any?(cwd, [".github/workflows", ".gitlab-ci.yml", "azure-pipelines.yml"]),
      has_lockfile: exists_any?(cwd, profile.lockfiles),
      has_readme: exists_any?(cwd, ["README.md", "README.rst", "README"]),
      has_license: exists_any?(cwd, ["LICENSE", "LICENSE.md", "COPYING"]),
      has_docs_dir: exists_any?(cwd, ["docs", "doc"]),
      has_gitignore: exists_any?(cwd, [".gitignore"]),
      has_project_rules: exists_any?(cwd, [".yokerules", ".yoke/rules.md", ".yoke/SYSTEM.md"]),
      has_practices: exists_any?(cwd, [".yoke/practices"]),
      quality_gates: Profiles.detect_quality_gates(cwd, profile),
      ci_workflows: ci_workflows(cwd)
    }
  end

  defp health(cwd, profile, source_files, test_files) do
    source_count = length(source_files)
    test_count = length(test_files)
    supports_sibling_tests? = profile.test_mappings != []

    %{
      git_dirty?: safe(fn -> Yoke.Git.dirty?(cwd) end, nil),
      base_branch: safe(fn -> Yoke.Git.default_base_branch(cwd) end, nil),
      test_to_source_ratio:
        if(source_count == 0, do: nil, else: Float.round(test_count / source_count, 2)),
      supports_sibling_tests?: supports_sibling_tests?,
      untested_files:
        if(supports_sibling_tests?,
          do: untested_files(cwd, profile.test_mappings, source_files, test_files),
          else: []
        )
    }
  end

  # Source files whose sibling test file does not exist, evaluated on the full
  # relative path (not basename) according to the active language mapping(s).
  defp untested_files(cwd, mappings, source_files, test_files) do
    test_paths = MapSet.new(test_files, &relative(&1, cwd))

    source_files
    |> Enum.filter(fn path ->
      rel = relative(path, cwd)
      expected = Enum.find_value(mappings, &Profiles.expected_test_path(rel, &1))
      expected != nil and not MapSet.member?(test_paths, expected)
    end)
    |> Enum.map(&relative(&1, cwd))
    |> Enum.sort()
    |> Enum.take(@max_modules_listed)
  end

  defp relative(path, cwd), do: Path.relative_to(Path.expand(path), Path.expand(cwd))

  defp markers(cwd, source_files, test_set) do
    source_files
    |> Enum.reject(&marker_noise?(cwd, &1, test_set))
    |> Enum.flat_map(fn path ->
      case File.read(path) do
        {:ok, content} ->
          content
          |> String.split("\n")
          |> Enum.with_index(1)
          |> Enum.filter(fn {line, _} -> Regex.match?(@marker_regex, line) end)
          |> Enum.map(fn {line, number} ->
            %{
              file: Path.relative_to(path, cwd),
              line: number,
              text: String.trim(line) |> String.slice(0, 160)
            }
          end)

        _ ->
          []
      end
    end)
    |> Enum.take(50)
  end

  # Exclude test files and this module itself (whose regex/headings spell out
  # the marker keywords).
  defp marker_noise?(cwd, path, test_set) do
    relative = relative(path, cwd)
    relative == "lib/yoke/audit.ex" or MapSet.member?(test_set, path)
  end

  defp ci_workflows(cwd) do
    case File.ls(Path.join(cwd, ".github/workflows")) do
      {:ok, entries} ->
        entries |> Enum.filter(&String.ends_with?(&1, [".yml", ".yaml"])) |> Enum.sort()

      _ ->
        []
    end
  end

  # ---------------------------------------------------------------------
  # Rendering
  # ---------------------------------------------------------------------

  @doc """
  Renders the collected facts as a compact Markdown block for terminal display
  or for embedding in the agent prompt.
  """
  @spec format_facts(map()) :: String.t()
  def format_facts(facts) do
    shape = facts.shape
    hygiene = facts.hygiene
    health = facts.health

    largest =
      case shape.largest_modules do
        [] ->
          "  (no source files found)"

        modules ->
          Enum.map_join(modules, "\n", fn {path, lines} -> "  • `#{path}` — #{lines} lines" end)
      end

    markers =
      case facts.markers do
        [] ->
          "  (none)"

        list ->
          Enum.map_join(Enum.take(list, 10), "\n", &"  • `#{&1.file}:#{&1.line}` — #{&1.text}")
      end

    inline_note =
      if shape.inline_tested_count > 0,
        do: " • Inline-tested source files: #{shape.inline_tested_count}",
        else: ""

    tools_line =
      case hygiene.tools do
        [] ->
          ""

        tools ->
          rendered =
            Enum.map_join(tools, " • ", fn t -> "#{t.label}: #{tool_flag(t.status)}" end)

          "\n- #{rendered}"
      end

    untested_section =
      if health.supports_sibling_tests? do
        untested =
          case health.untested_files do
            [] -> "  (none — every source file has a matching test file)"
            files -> Enum.map_join(files, "\n", &"  • `#{&1}`")
          end

        "\n- Source files with no obvious matching test file:\n#{untested}"
      else
        ""
      end

    plugin_line =
      case Yoke.ElixirPlugins.format_summary(Map.get(facts, :elixir_plugins)) do
        "" -> ""
        summary -> "\n\n**Elixir Language Plugins (diff)**\n- #{summary}"
      end

    """
    ### Project facts

    **Shape**
    - Languages: #{inspect(shape.languages)}
    - Source files: #{shape.source_file_count} (#{shape.source_lines} lines) • Test files: #{shape.test_file_count}#{inline_note}
    - Test/source file ratio: #{inspect(health.test_to_source_ratio)}
    - Largest modules:
    #{largest}

    **Hygiene**#{tools_line}
    - CI: #{flag(hygiene.has_ci)} #{inspect(hygiene.ci_workflows)} • Lockfile: #{flag(hygiene.has_lockfile)}
    - README: #{flag(hygiene.has_readme)} • LICENSE: #{flag(hygiene.has_license)} • docs/: #{flag(hygiene.has_docs_dir)}
    - Project rules: #{flag(hygiene.has_project_rules)} • Practices: #{flag(hygiene.has_practices)}
    - Quality gates: #{inspect(hygiene.quality_gates)}

    **Health**
    - Git dirty: #{inspect(health.git_dirty?)} • Base branch: #{inspect(health.base_branch)}#{untested_section}#{plugin_line}

    **Markers (TODO/FIXME/HACK/XXX/OPTIMIZE)**
    #{markers}
    """
  end

  @doc """
  Builds the agent prompt for a full project audit.

  ## Options

    * `:focus` — `:all` (default), `:code`, or `:ux`, to narrow the audit.
  """
  @spec build_prompt(map(), keyword()) :: String.t()
  def build_prompt(facts, opts \\ []) do
    focus = Keyword.get(opts, :focus, :all)

    plugin_section =
      case Yoke.ElixirPlugins.format_for_prompt(Map.get(facts, :elixir_plugins)) do
        "" -> ""
        formatted -> "\n#{formatted}\n"
      end

    """
    ### Project audit

    You are auditing this project end to end. The facts below were measured
    directly from the workspace — treat them as ground truth, and verify
    anything you want to claim by reading the code yourself.

    #{format_facts(facts)}
    #{plugin_section}
    ### Deliverable

    Respond with exactly these four sections, in this order.

    #{section_specs(focus)}

    ### Rules

    - Ground every claim in evidence: a file path, a line, a measured number.
      "Consider adding tests" is worthless; citing a specific module, its line
      count, and the untested branching logic inside it is actionable.
    - Distinguish **defects** (wrong behaviour, broken invariants) from
      **smells** (works, but will hurt later) from **taste** (fine either way).
      Do not inflate taste into defects.
    - Rank each finding by impact. Lead with the ones a maintainer would fix
      this week.
    - If the project is genuinely in good shape in some area, say so plainly
      and name the mechanism that keeps it good — that is the "strong parts"
      section's whole job.
    - Do not propose rewrites. Propose the smallest change that removes the
      problem.
    - When `propwise` identifies property-based testing candidates in the diff,
      present them as **actual test improvements** (concrete `ExUnit` /
      `ExUnitProperties` `property` tests targeting the corresponding
      `*_test.exs` file) whenever applicable.
    """
  end

  defp section_specs(:code) do
    """
    **1. Strong parts**
    What is genuinely well built, and *why* it holds up. Cite the mechanism
    (a test, a type boundary, an ownership/concurrency invariant), not just the file.

    **2. Weaknesses & glitches to fix**
    Concrete defects and structural problems, worst first. For each: the
    location, what breaks or will break, and the fix.

    **3. Improvement ideas**
    Changes that would make the codebase better without a rewrite. Order by
    value-for-effort.
    """
  end

  defp section_specs(:ux) do
    """
    **1. Strong parts**
    Which parts of the user-facing experience already work well, and why.

    **2. Weaknesses & glitches to fix**
    Every rough edge a user hits: unclear errors, missing feedback, confusing
    defaults, dead ends, inconsistent naming, slow paths. Worst first.

    **3. UX improvement ideas**
    Concrete improvements to the CLI/API/UI surface, ordered by
    value-for-effort, each with the specific change described.
    """
  end

  defp section_specs(_all) do
    """
    **1. Strong parts**
    What is genuinely well built, and *why* it holds up. Cite the mechanism
    (a test, a type boundary, an ownership/concurrency invariant), not just the file.

    **2. Weaknesses & glitches to fix**
    Concrete defects and structural problems, worst first. For each: the
    location, what breaks or will break, and the fix.

    **3. Codebase improvement ideas**
    Changes that would make the code better without a rewrite. Order by
    value-for-effort.

    **4. UX improvement ideas**
    Every rough edge a user hits — unclear errors, missing feedback, confusing
    defaults, dead ends, inconsistent naming, slow paths — plus the concrete
    change that removes it. Order by value-for-effort.
    """
  end

  @doc """
  Renders the one-line header printed before the agent's audit narrative.
  """
  @spec format_header(map()) :: String.t()
  def format_header(facts) do
    """
    #{Formatter.bold()}=== Project Audit ===#{Formatter.reset()}
    #{Formatter.cyan()}●#{Formatter.reset()} #{facts.cwd}
    #{Formatter.dim()}Measured #{facts.shape.source_file_count} source / #{facts.shape.test_file_count} test files, #{facts.shape.source_lines} source lines. Handing the facts to the agent for the narrative audit…#{Formatter.reset()}
    """
  end

  # ---------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------

  defp glob(cwd, patterns, root, ignore_dirs) do
    expanded_root = Path.expand(root)

    patterns
    |> Enum.flat_map(fn pattern -> Path.wildcard(Path.join(cwd, pattern)) end)
    |> Enum.reject(&noise?(expanded_root, &1, ignore_dirs))
    |> Enum.filter(&File.regular?/1)
    |> Enum.uniq()
  end

  defp noise?(root, path, ignore_dirs) do
    relative = Path.relative_to(Path.expand(path), root)
    parts = Path.split(relative)
    Enum.any?(ignore_dirs, &(&1 in parts))
  end

  defp line_count(path) do
    case File.read(path) do
      {:ok, content} -> length(String.split(content, "\n"))
      _ -> 0
    end
  end

  defp exists_any?(cwd, candidates) do
    Enum.any?(candidates, fn candidate -> File.exists?(Path.join(cwd, candidate)) end)
  end

  defp flag(true), do: "✓"
  defp flag(false), do: "✗"
  defp flag(_), do: "?"

  defp tool_flag(:configured), do: "✓"
  defp tool_flag(:builtin), do: "✓ (built-in)"
  defp tool_flag(_), do: "✗"

  defp safe(fun, default) do
    fun.()
  rescue
    _ -> default
  catch
    _, _ -> default
  end
end
