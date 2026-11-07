defmodule Yoke.Audit do
  @moduledoc """
  Whole-project audit engine behind the `/audit` REPL command and
  `yoke audit --project`.

  The audit has two halves, deliberately kept separate:

  ## 1. Deterministic facts (this module)

  Cheap, reproducible measurements gathered straight from the workspace — no
  LLM call, no network. They exist so the agent's narrative is *grounded*:
  every claim it makes can be checked against a number produced here.

    * **Shape** — languages, source/test file counts, line counts, largest
      modules, `TODO`/`FIXME`/`HACK` markers.
    * **Hygiene** — formatter/credo/dialyzer configuration, CI workflows,
      lockfiles, docs, license, `.gitignore` coverage of build artifacts.
    * **Health** — whether the project's own quality gate is wired up
      (`mix quality`, `mix quality.ci`), test-to-source ratio, and the git
      working-tree state.

  ## 2. Narrative (the agent)

  The facts are rendered into a prompt that asks for four sections: **strong
  parts**, **weaknesses & glitches**, **codebase improvements**, and **UX
  improvements**. The prompt insists on evidence — file paths and numbers —
  and forbids generic advice that would apply to any project.

  ## Why not just ask the model "audit my project"?

  Because an ungrounded audit is a horoscope: it will confidently praise
  "good separation of concerns" in a 40-line script and warn about "potential
  N+1 queries" in a repo with no database. Feeding measured facts first keeps
  the output falsifiable.
  """

  alias Yoke.CLI.Formatter

  @marker_regex ~r/\b(TODO|FIXME|HACK|XXX|OPTIMIZE)\b/
  @max_modules_listed 15

  @doc """
  Collects deterministic audit facts for the workspace at `cwd`.

  Returns a plain map (no struct) so it renders to JSON trivially and stays
  easy to extend.
  """
  @spec collect(String.t()) :: map()
  def collect(cwd \\ ".") do
    source_files = glob(cwd, ["lib/**/*.ex", "src/**/*", "app/**/*.py", "**/*.rb"], cwd)
    test_files = glob(cwd, ["test/**/*.exs", "test/**/*.ex", "tests/**/*.py"], cwd)

    %{
      cwd: Path.expand(cwd),
      shape: shape(cwd, source_files, test_files),
      hygiene: hygiene(cwd),
      health: health(cwd, source_files, test_files),
      markers: markers(cwd, source_files ++ test_files)
    }
  end

  # ---------------------------------------------------------------------
  # Facts
  # ---------------------------------------------------------------------

  defp shape(cwd, source_files, test_files) do
    sizes =
      source_files
      |> Enum.map(fn path -> {path, line_count(path)} end)
      |> Enum.sort_by(fn {_path, lines} -> -lines end)

    %{
      languages: safe(fn -> Yoke.Practices.detect_languages(cwd) end, []),
      source_file_count: length(source_files),
      test_file_count: length(test_files),
      source_lines: sizes |> Enum.map(&elem(&1, 1)) |> Enum.sum(),
      largest_modules: Enum.take(sizes, @max_modules_listed)
    }
  end

  defp hygiene(cwd) do
    %{
      has_formatter: exists_any?(cwd, [".formatter.exs", "rustfmt.toml", ".prettierrc"]),
      has_credo: exists_any?(cwd, [".credo.exs", ".credo.ex"]),
      has_dialyzer: exists_any?(cwd, [".dialyzer_ignore.exs", "dialyzer.ignore-warnings"]),
      has_ci: exists_any?(cwd, [".github/workflows", ".gitlab-ci.yml", "azure-pipelines.yml"]),
      has_lockfile:
        exists_any?(cwd, ["mix.lock", "Cargo.lock", "package-lock.json", "poetry.lock"]),
      has_readme: exists_any?(cwd, ["README.md", "README.rst", "README"]),
      has_license: exists_any?(cwd, ["LICENSE", "LICENSE.md", "COPYING"]),
      has_docs_dir: exists_any?(cwd, ["docs", "doc"]),
      has_gitignore: exists_any?(cwd, [".gitignore"]),
      has_project_rules: exists_any?(cwd, [".yokerules", ".yoke/rules.md", ".yoke/SYSTEM.md"]),
      has_practices: exists_any?(cwd, [".yoke/practices"]),
      quality_aliases: quality_aliases(cwd),
      ci_workflows: ci_workflows(cwd)
    }
  end

  defp health(cwd, source_files, test_files) do
    source_count = length(source_files)
    test_count = length(test_files)

    %{
      git_dirty?: safe(fn -> Yoke.Git.dirty?(cwd) end, nil),
      base_branch: safe(fn -> Yoke.Git.default_base_branch(cwd) end, nil),
      test_to_source_ratio:
        if(source_count == 0, do: nil, else: Float.round(test_count / source_count, 2)),
      untested_dirs: untested_dirs(cwd, source_files, test_files)
    }
  end

  # Source files whose sibling test file does not exist. Elixir convention is
  # `lib/foo/bar.ex` -> `test/foo/bar_test.exs`; anything else is reported as
  # "no obvious test file" rather than "untested" (it may be covered
  # indirectly, which is exactly what the agent should verify).
  defp untested_dirs(cwd, source_files, test_files) do
    test_basenames = MapSet.new(test_files, &Path.basename/1)

    source_files
    |> Enum.filter(&String.ends_with?(&1, ".ex"))
    |> Enum.reject(fn path ->
      expected = String.replace_suffix(Path.basename(path), ".ex", "_test.exs")
      MapSet.member?(test_basenames, expected)
    end)
    |> Enum.map(&Path.relative_to(&1, cwd))
    |> Enum.take(@max_modules_listed)
  end

  defp markers(cwd, files) do
    files
    |> Enum.reject(&marker_noise?(cwd, &1))
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

  # Two sources of pure noise in a marker scan:
  #
  #   * this module itself, whose regex and section headings literally spell
  #     out the marker keywords;
  #   * test files, whose fixtures deliberately contain `TODO`/`FIXME` text.
  #
  # Neither is a real outstanding task, and including them makes the report
  # look like it has work queued when it does not.
  defp marker_noise?(cwd, path) do
    relative = Path.relative_to(Path.expand(path), Path.expand(cwd))
    relative == "lib/yoke/audit.ex" or String.starts_with?(relative, "test/")
  end

  # Matches both the keyword form (`quality: [...]`, as written inside a
  # `def project` body) and the string-keyed form (`"quality" => [...]`, as
  # seen in a `Map`-style alias table).
  defp quality_aliases(cwd) do
    case File.read(Path.join(cwd, "mix.exs")) do
      {:ok, content} ->
        for name <- ["quality", "quality.ci"],
            String.contains?(content, ["\"#{name}\"", "#{name}:"]),
            do: name

      _ ->
        []
    end
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

    untested =
      case health.untested_dirs do
        [] -> "  (none — every source file has a matching test file)"
        dirs -> Enum.map_join(dirs, "\n", &"  • `#{&1}`")
      end

    """
    ### Project facts

    **Shape**
    - Languages: #{inspect(shape.languages)}
    - Source files: #{shape.source_file_count} (#{shape.source_lines} lines) • Test files: #{shape.test_file_count}
    - Test/source file ratio: #{inspect(health.test_to_source_ratio)}
    - Largest modules:
    #{largest}

    **Hygiene**
    - Formatter: #{flag(hygiene.has_formatter)} • Credo: #{flag(hygiene.has_credo)} • Dialyzer: #{flag(hygiene.has_dialyzer)}
    - CI: #{flag(hygiene.has_ci)} #{inspect(hygiene.ci_workflows)} • Lockfile: #{flag(hygiene.has_lockfile)}
    - README: #{flag(hygiene.has_readme)} • LICENSE: #{flag(hygiene.has_license)} • docs/: #{flag(hygiene.has_docs_dir)}
    - Project rules: #{flag(hygiene.has_project_rules)} • Practices: #{flag(hygiene.has_practices)}
    - Quality aliases in mix.exs: #{inspect(hygiene.quality_aliases)}

    **Health**
    - Git dirty: #{inspect(health.git_dirty?)} • Base branch: #{inspect(health.base_branch)}
    - Source files with no obvious matching test file:
    #{untested}

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

    """
    ### Project audit

    You are auditing this project end to end. The facts below were measured
    directly from the workspace — treat them as ground truth, and verify
    anything you want to claim by reading the code yourself.

    #{format_facts(facts)}

    ### Deliverable

    Respond with exactly these four sections, in this order.

    #{section_specs(focus)}

    ### Rules

    - Ground every claim in evidence: a file path, a line, a measured number.
      "Consider adding tests" is worthless; "`lib/yoke/foo.ex` has no
      `foo_test.exs` and holds 412 lines of branching logic" is actionable.
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
    """
  end

  defp section_specs(:code) do
    """
    **1. Strong parts**
    What is genuinely well built, and *why* it holds up. Cite the mechanism
    (a test, a type boundary, a supervision strategy), not just the file.

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
    (a test, a type boundary, a supervision strategy), not just the file.

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

  # Globs relative to `cwd`, skipping the usual noise directories. `lib/**`
  # style patterns are matched with Path.wildcard/2 which is fast enough for
  # the project sizes this command is meant for.
  defp glob(cwd, patterns, root) do
    patterns
    |> Enum.flat_map(fn pattern -> Path.wildcard(Path.join(cwd, pattern)) end)
    |> Enum.reject(&noise?(Path.expand(root), &1))
    |> Enum.filter(&File.regular?/1)
    |> Enum.uniq()
  end

  @noise ~w(deps _build node_modules .git .elixir_ls target build dist .yoke tmp)

  # Only the path *relative to the project root* decides whether a file is
  # noise. Checking the absolute path would disqualify every project that
  # happens to live under a directory named e.g. `tmp` or `build`
  # (`/tmp/myproj`, `/home/u/build/myproj`), reporting zero source files.
  defp noise?(root, path) do
    relative = Path.relative_to(Path.expand(path), root)
    parts = Path.split(relative)
    Enum.any?(@noise, &(&1 in parts))
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

  defp safe(fun, default) do
    fun.()
  rescue
    _ -> default
  catch
    _, _ -> default
  end
end
