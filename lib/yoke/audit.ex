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
    * `:root` — audit a directory other than `cwd` (see `resolve_root/2`).
    * `:allow_nested_root` — never refuse and never redirect to a nested
      project, even when `cwd` itself looks like a project (see
      `resolve_root/2`).

  ## Scope

  A zero-file scan is reported as scope information, never as a clean bill of
  health. `collect/2` therefore records `scope` (the resolved root, whether it
  was redirected, and any nested project roots it found) and `notes` (plain
  sentences naming what could not be measured), and `format_facts/1` renders
  both before any other fact.
  """
  @spec collect(String.t(), keyword()) :: map()
  def collect(cwd \\ ".", opts \\ []) do
    scope = resolve_root(cwd, opts)
    root = scope.root

    detected_languages = safe(fn -> Yoke.Practices.detect_languages(root) end, [])
    profile = Profiles.resolve(root, detected_languages, opts)

    test_files = glob(root, profile.test_globs, root, profile.ignore_dirs)
    test_set = MapSet.new(test_files)

    source_files =
      root
      |> glob(profile.source_globs, root, profile.ignore_dirs)
      |> Enum.reject(&MapSet.member?(test_set, &1))

    health_facts = health(root, profile, source_files, test_files)
    shape_facts = shape(profile, source_files, test_files)

    elixir_plugins =
      if "elixir" in profile.languages do
        collect_elixir_plugins(root, health_facts.base_branch, opts)
      else
        nil
      end

    %{
      cwd: root,
      scope: scope,
      shape: shape_facts,
      hygiene: hygiene(root, profile),
      health: health_facts,
      markers: markers(root, source_files, test_set),
      notes: notes(%{scope: scope, shape: shape_facts, health: health_facts}),
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
  # Scope
  # ---------------------------------------------------------------------

  # Directories that can never be a project root, so a monorepo-style scan
  # does not descend into dependencies or build output.
  @nested_root_ignore_dirs ~w(deps _build node_modules .git .elixir_ls target build dist .yoke tmp .venv venv __pycache__)

  # Markers that make a directory a project root in its own right.
  @project_root_markers ~w(
    mix.exs Cargo.toml go.mod package.json pyproject.toml setup.py setup.cfg
    Gemfile pom.xml build.gradle build.gradle.kts settings.gradle settings.gradle.kts
    CMakeLists.txt meson.build
  )

  @max_nested_roots 10

  @doc """
  Resolves which directory an audit actually measures.

  Auditing a container directory that holds the project one level down (the
  common `workspace/app/` layout) used to report zero source files, no
  formatter, and a clean working tree — measurements that read as a clean bill
  of health when they only mean "nothing was scanned here".

  The rules, in order:

    1. `:root` (or `:allow_nested_root`) disables every heuristic below.
    2. `cwd` is a project root when it has a project marker, or when it has
       language source files and its own test directory. It is then audited
       as given.
    3. Otherwise, the project roots strictly below `cwd` are collected. Exactly
       one redirects the audit to it (`redirected?: true`); several are
       reported as ambiguous and none is chosen.

  Returns a map with `:root` (absolute path), `:requested` (absolute path of
  the directory asked for), `:redirected?`, `:nested_roots`, and `:reason`.
  """
  @spec resolve_root(String.t(), keyword()) :: map()
  def resolve_root(cwd \\ ".", opts \\ []) do
    requested = Path.expand(cwd)

    cond do
      is_binary(Keyword.get(opts, :root)) ->
        scope(Path.expand(Keyword.fetch!(opts, :root)), requested, :explicit)

      Keyword.get(opts, :allow_nested_root, false) ->
        scope(requested, requested, :project)

      project_root?(requested) ->
        scope(requested, requested, :project)

      true ->
        resolve_nested_root(requested)
    end
  end

  # Plain sentences naming what the deterministic facts could not measure.
  # Rendered ahead of every other fact so a zero-file scan cannot be mistaken
  # for a clean project assessment.
  defp notes(%{scope: scope, shape: shape, health: health}) do
    scope_notes(scope) ++ zero_file_notes(shape) ++ git_notes(health)
  end

  defp scope_notes(%{reason: :nested_project, requested: requested, root: root}) do
    [
      "No project root at `#{requested}`; audited the nested project `#{root}` instead. " <>
        "Pass `--root <dir>` to audit a different directory."
    ]
  end

  defp scope_notes(%{reason: :ambiguous_nested_projects, nested_roots: roots}) do
    listed = Enum.map_join(Enum.take(roots, @max_nested_roots), ", ", &"`#{&1}`")

    [
      "No project root at the audited directory and #{length(roots)} nested projects were " <>
        "found (#{listed}); none was chosen. Pass `--root <dir>` to select one."
    ]
  end

  defp scope_notes(%{reason: :no_project, requested: requested}) do
    [
      "No project root found at `#{requested}`: no project manifest (mix.exs, Cargo.toml, " <>
        "package.json, …) and no source/test layout. The facts below describe an empty scan, " <>
        "not a healthy project."
    ]
  end

  defp scope_notes(_scope), do: []

  defp zero_file_notes(%{source_file_count: 0, test_file_count: 0}) do
    [
      "No source or test files matched the audit globs. This is scope information, not a " <>
        "clean-project assessment."
    ]
  end

  defp zero_file_notes(_shape), do: []

  defp git_notes(%{git_dirty?: nil}), do: ["Git working-tree state could not be measured."]

  defp git_notes(%{git_dirty?: false, git_tracked?: false}) do
    [
      "Git working-tree state is unknown: the audited directory is not a Git repository, " <>
        "so \"not dirty\" does not mean clean."
    ]
  end

  defp git_notes(_health), do: []

  defp scope(root, requested, reason) do
    %{
      root: root,
      requested: requested,
      redirected?: root != requested,
      nested_roots: [],
      reason: reason
    }
  end

  defp resolve_nested_root(requested) do
    case nested_project_roots(requested) do
      [only] ->
        %{
          root: only,
          requested: requested,
          redirected?: true,
          nested_roots: [only],
          reason: :nested_project
        }

      [] ->
        scope(requested, requested, :no_project)

      several ->
        %{
          root: requested,
          requested: requested,
          redirected?: false,
          nested_roots: several,
          reason: :ambiguous_nested_projects
        }
    end
  end

  defp project_root?(dir) do
    Enum.any?(@project_root_markers, &File.regular?(Path.join(dir, &1))) or
      (has_language_source?(dir) and
         Enum.any?(["test", "tests", "spec"], &File.dir?(Path.join(dir, &1))))
  end

  defp has_language_source?(dir) do
    ["lib", "src", "app", "pkg", "internal"]
    |> Enum.any?(fn sub -> File.dir?(Path.join(dir, sub)) end)
  end

  defp nested_project_roots(dir) do
    dir
    |> collect_nested_roots(0, [])
    |> Enum.reverse()
  end

  defp collect_nested_roots(_dir, depth, acc) when depth > 3, do: acc

  defp collect_nested_roots(dir, depth, acc) do
    case File.ls(dir) do
      {:ok, entries} ->
        entries
        |> Enum.reject(&(&1 in @nested_root_ignore_dirs))
        |> Enum.sort()
        |> Enum.reduce(acc, fn entry, acc ->
          path = Path.join(dir, entry)

          cond do
            not File.dir?(path) ->
              acc

            project_root?(path) ->
              [path | acc]

            true ->
              collect_nested_roots(path, depth + 1, acc)
          end
        end)

      _ ->
        acc
    end
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
      git_tracked?: safe(fn -> match?({:ok, _}, Yoke.Git.status(cwd)) end, false),
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
      cond do
        not health.supports_sibling_tests? ->
          ""

        health.untested_files == [] and shape.source_file_count == 0 ->
          ""

        health.untested_files == [] ->
          "\n- Source files with no obvious matching test file:\n" <>
            "  (none — every source file has a matching test file)"

        true ->
          untested = Enum.map_join(health.untested_files, "\n", &"  • `#{&1}`")
          "\n- Source files with no obvious matching test file:\n#{untested}"
      end

    plugin_line =
      case Yoke.ElixirPlugins.format_summary(Map.get(facts, :elixir_plugins)) do
        "" -> ""
        summary -> "\n\n**Elixir Language Plugins (diff)**\n- #{summary}"
      end

    scope_section = format_scope(facts)

    """
    ### Project facts

    #{scope_section}**Shape**
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
    - Git dirty: #{git_flag(health)} • Base branch: #{inspect(health.base_branch)}#{untested_section}#{plugin_line}

    **Markers (TODO/FIXME/HACK/XXX/OPTIMIZE)**
    #{markers}
    """
  end

  @doc """
  Renders the audit scope: which directory was measured, whether it was
  redirected to a nested project, and every measurement that failed or was
  skipped.

  Returns `""` when the audit measured the requested project root and every
  fact was measurable, so an ordinary healthy project keeps its compact facts
  block.
  """
  @spec format_scope(map()) :: String.t()
  def format_scope(facts) do
    scope = Map.get(facts, :scope)
    notes = Map.get(facts, :notes, [])

    lines = scope_context(scope) ++ Enum.map(notes, &"- #{&1}")

    case lines do
      [] -> ""
      lines -> "**Scope**\n" <> Enum.join(lines, "\n") <> "\n\n"
    end
  end

  defp scope_context(nil), do: []

  defp scope_context(%{redirected?: true, requested: requested, root: root}) do
    ["- Audited root: `#{root}` (redirected from `#{requested}`)"]
  end

  defp scope_context(%{root: root}), do: ["- Audited root: `#{root}`"]

  defp git_flag(%{git_dirty?: false, git_tracked?: false}), do: "unknown (not a Git repository)"
  defp git_flag(%{git_dirty?: dirty}), do: inspect(dirty)

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
    - Read the **Scope** block first. A zero-file scan, an empty root, an
      unmeasurable Git state, or a nested project that was not audited is
      scope information, not evidence that the project is healthy. Never
      describe such a project as clean; say what could not be measured and
      how to measure it (`--root <dir>`).
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

  When the audit was redirected to a nested project, the header names both the
  requested directory and the one actually measured, so a redirected audit is
  never mistaken for a scan of the directory the user ran it from.
  """
  @spec format_header(map()) :: String.t()
  def format_header(facts) do
    """
    #{Formatter.bold()}=== Project Audit ===#{Formatter.reset()}
    #{Formatter.cyan()}●#{Formatter.reset()} #{facts.cwd}#{redirect_line(facts)}
    #{Formatter.dim()}Measured #{facts.shape.source_file_count} source / #{facts.shape.test_file_count} test files, #{facts.shape.source_lines} source lines. Handing the facts to the agent for the narrative audit…#{Formatter.reset()}
    """
  end

  defp redirect_line(%{scope: %{redirected?: true, requested: requested}}) do
    "\n#{Formatter.yellow()}●#{Formatter.reset()} requested #{requested}; no project root there, " <>
      "auditing the nested project instead"
  end

  defp redirect_line(_facts), do: ""

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
