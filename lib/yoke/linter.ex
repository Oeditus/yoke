defmodule Yoke.Linter do
  @moduledoc """
  Linter and static analysis tool orchestrator for Yoke (ragec).
  Executes native Elixir tools like `oeditus_credo`, `propwise`, `credo`, and `dialyzer`
  across the full project, git working tree diffs, or code reviews (CRs).
  """

  @doc "Returns list of available linter tools and their details."
  def list_tools do
    [
      %{
        name: "metacredo",
        aliases: ["meta_credo", "meta-credo"],
        description:
          "Cross-language static analysis via MetaCredo (~70 security, warning, design, readability, and refactoring checks across Elixir, Go, JS/TS, Rust, Python, Ruby, etc.)",
        docs: "https://hexdocs.pm/metacredo"
      },
      %{
        name: "oeditus_credo",
        aliases: ["oeditus-credo", "oeditus"],
        description:
          "Custom Credo checks for Elixir/Phoenix anti-patterns and CWE Top 25 security vulnerabilities",
        docs: "https://oeditus_credo.hexdocs.pm"
      },
      %{
        name: "propwise",
        aliases: [],
        description:
          "AST-based analyzer for identifying property-based testing candidates in Elixir codebases",
        docs: "https://propwise.hexdocs.pm"
      },
      %{
        name: "credo",
        aliases: [],
        description: "Standard Credo static analysis tool",
        docs: "https://hexdocs.pm/credo"
      },
      %{
        name: "dialyzer",
        aliases: [],
        description: "Dialyxir static type analysis tool",
        docs: "https://hexdocs.pm/dialyxir"
      },
      %{
        name: "prisma",
        aliases: [],
        description:
          "Prisma hybrid success/gradual type analyzer for compiled Elixir/Erlang beams",
        docs: "https://prisma.hexdocs.pm"
      },
      %{
        name: "javac",
        aliases: ["java", "compile"],
        description: "Java compiler & type checker (via ./mvnw test-compile, gradle, or javac)",
        docs: "https://openjdk.org"
      },
      %{
        name: "mvn",
        aliases: ["maven"],
        description: "Maven execution wrapper (via ./mvnw or mvn)",
        docs: "https://maven.apache.org"
      },
      %{
        name: "checkstyle",
        aliases: [],
        description: "Java style and smell checks (via checkstyle:check)",
        docs: "https://checkstyle.sourceforge.io"
      },
      %{
        name: "cargo",
        aliases: ["cargo_check", "rust"],
        description: "Rust compiler & borrow checker (via cargo check --all-targets)",
        docs: "https://doc.rust-lang.org/cargo/commands/cargo-check.html"
      },
      %{
        name: "clippy",
        aliases: ["cargo_clippy"],
        description: "Rust linter and idiomatic style checks (via cargo clippy --all-targets)",
        docs: "https://doc.rust-lang.org/clippy/"
      },
      %{
        name: "go",
        aliases: ["go_vet", "golang"],
        description: "Go static analysis and vet checks (via go vet ./...)",
        docs: "https://pkg.go.dev/cmd/vet"
      },
      %{
        name: "all",
        aliases: [],
        description: "Run all supported linter tools in sequence",
        docs: ""
      }
    ]
  end

  @doc """
  Runs the specified linter tool against project, diff, or CR targets.

  ## Examples
      Yoke.Linter.run("propwise cr main")
      Yoke.Linter.run("oeditus_credo diff")
      Yoke.Linter.run("all project")
  """
  def run(input \\ "", cwd \\ ".", provider_opts \\ [])

  def run(input, cwd, provider_opts) when is_binary(input) do
    trimmed = String.trim(input)

    cond do
      trimmed == "" or trimmed == "help" ->
        {:ok, help_text()}

      String.starts_with?(trimmed, "fix ") or trimmed == "fix" ->
        target_input =
          if trimmed == "fix",
            do: "credo",
            else: String.trim_leading(trimmed, "fix ") |> String.trim()

        target_input = if target_input == "", do: "credo", else: target_input
        parts = String.split(target_input, " ", trim: true)
        [tool | _] = parts

        case run(target_input, cwd, provider_opts) do
          {:ok, output} -> Yoke.Linter.Interactive.run(output, tool, cwd, provider_opts)
          error -> error
        end

      true ->
        parts = String.split(trimmed, " ", trim: true)
        [tool | rest] = parts
        normalize_and_run(tool, rest, cwd)
    end
  end

  def normalize_and_run(tool, rest, cwd) do
    canonical_tool = canonicalize_tool(tool)

    case canonical_tool do
      :unknown ->
        {:error,
         "Unknown linter tool: '#{tool}'. Available tools: #{Enum.map_join(list_tools(), ", ", & &1.name)}\n\n#{help_text()}"}

      :all ->
        run_all(rest, cwd)

      tool_name ->
        run_single_tool(tool_name, rest, cwd)
    end
  end

  defp canonicalize_tool(tool) do
    case String.downcase(tool) do
      t when t in ["metacredo", "meta_credo", "meta-credo"] -> "metacredo"
      t when t in ["oeditus_credo", "oeditus-credo", "oeditus"] -> "oeditus_credo"
      "propwise" -> "propwise"
      "credo" -> "credo"
      "dialyzer" -> "dialyzer"
      "prisma" -> "prisma"
      t when t in ["javac", "java", "compile"] -> "javac"
      t when t in ["mvn", "maven"] -> "mvn"
      "checkstyle" -> "checkstyle"
      t when t in ["cargo", "cargo_check", "rust"] -> "cargo"
      t when t in ["clippy", "cargo_clippy"] -> "clippy"
      t when t in ["go", "go_vet", "golang"] -> "go"
      "all" -> :all
      "help" -> :unknown
      "list" -> :unknown
      _ -> :unknown
    end
  end

  defp run_all(rest, cwd) do
    tools =
      cond do
        not File.exists?(Path.join(cwd, "mix.exs")) and
            (File.exists?(Path.join(cwd, "pom.xml")) or
               File.exists?(Path.join(cwd, "build.gradle"))) ->
          ["javac"]

        not File.exists?(Path.join(cwd, "mix.exs")) and
            File.exists?(Path.join(cwd, "Cargo.toml")) ->
          ["cargo", "clippy"]

        not File.exists?(Path.join(cwd, "mix.exs")) and
            File.exists?(Path.join(cwd, "go.mod")) ->
          ["go"]

        true ->
          ["oeditus_credo", "propwise", "credo"]
      end

    results =
      Enum.map(tools, fn t ->
        case run_single_tool(t, rest, cwd) do
          {:ok, out} -> "=== Linter: #{t} ===\n#{out}\n"
          {:error, err} -> "=== Linter: #{t} (ERROR) ===\n#{err}\n"
        end
      end)

    {:ok, Enum.join(results, "\n" <> String.duplicate("-", 60) <> "\n\n")}
  end

  defp run_single_tool("javac", _rest, cwd) do
    exec_java_compile(cwd)
  end

  defp run_single_tool("mvn", rest, cwd) do
    exec_mvn(rest, cwd)
  end

  defp run_single_tool("checkstyle", rest, cwd) do
    exec_mvn(["checkstyle:check" | rest], cwd)
  end

  defp run_single_tool("cargo", rest, cwd) do
    exec_cargo(["check", "--all-targets" | filter_target_args(rest)], cwd)
  end

  defp run_single_tool("clippy", rest, cwd) do
    exec_cargo(["clippy", "--all-targets" | filter_target_args(rest)], cwd)
  end

  defp run_single_tool("go", rest, cwd) do
    exec_go(["vet", "./..." | filter_target_args(rest)], cwd)
  end

  defp run_single_tool("metacredo", rest, cwd) do
    exec_metacredo(rest, cwd)
  end

  defp run_single_tool("prisma", rest, cwd) do
    exec_prisma(rest, cwd)
  end

  defp run_single_tool(tool, rest, cwd) do
    {mode, target_args} = parse_mode(rest)

    case mode do
      :project ->
        exec_mix(tool, target_args, cwd)

      :diff ->
        target_ref = Enum.at(target_args, 0)
        run_on_diff(tool, target_ref, cwd)

      :cr ->
        base_ref = Enum.at(target_args, 0) || Yoke.Git.default_base_branch(cwd)
        head_ref = Enum.at(target_args, 1) || "HEAD"
        run_on_cr(tool, base_ref, head_ref, cwd)

      :custom_args ->
        exec_mix(tool, rest, cwd)
    end
  end

  defp parse_mode([]), do: {:project, []}
  defp parse_mode(["project" | rest]), do: {:project, rest}
  defp parse_mode(["diff" | rest]), do: {:diff, rest}
  defp parse_mode(["cr" | rest]), do: {:cr, rest}
  defp parse_mode(rest), do: {:custom_args, rest}

  defp run_on_diff(tool, target_ref, cwd) when tool in ["oeditus_credo", "credo"] do
    args = if target_ref && target_ref != "", do: ["diff", target_ref], else: ["diff"]
    exec_mix(tool, args, cwd)
  end

  defp run_on_diff("propwise", target_ref, cwd) do
    git_args =
      if target_ref && target_ref != "",
        do: ["diff", "--name-only", target_ref],
        else: ["diff", "--name-only"]

    case System.cmd("git", git_args, cd: cwd, stderr_to_stdout: true) do
      {files_str, 0} ->
        ex_files = filter_ex_files(files_str, cwd)

        if ex_files == [] do
          {:ok, "No changed Elixir files found in git diff."}
        else
          exec_mix("propwise", ["--files", Enum.join(ex_files, ",")], cwd)
        end

      {err, _} ->
        {:error, "Failed to inspect git diff: #{err}"}
    end
  end

  defp run_on_diff("dialyzer", _target_ref, cwd) do
    exec_mix("dialyzer", [], cwd)
  end

  defp run_on_cr(tool, base_ref, head_ref, cwd) when tool in ["oeditus_credo", "credo"] do
    ref_arg = if head_ref == "HEAD", do: base_ref, else: "#{base_ref}..#{head_ref}"
    exec_mix(tool, ["diff", ref_arg], cwd)
  end

  defp run_on_cr("propwise", base_ref, head_ref, cwd) do
    range = "#{base_ref}...#{head_ref}"

    case System.cmd("git", ["diff", "--name-only", range], cd: cwd, stderr_to_stdout: true) do
      {files_str, 0} ->
        ex_files = filter_ex_files(files_str, cwd)

        if ex_files == [] do
          {:ok, "No changed Elixir files found between '#{base_ref}' and '#{head_ref}'."}
        else
          exec_mix("propwise", ["--files", Enum.join(ex_files, ",")], cwd)
        end

      {err, _} ->
        {:error, "Failed to inspect git diff for range #{range}: #{err}"}
    end
  end

  defp run_on_cr("dialyzer", _base_ref, _head_ref, cwd) do
    exec_mix("dialyzer", [], cwd)
  end

  defp filter_ex_files(files_str, cwd) do
    files_str
    |> String.split("\n", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.filter(fn path ->
      (String.ends_with?(path, ".ex") or String.ends_with?(path, ".exs")) and
        File.exists?(Path.join(cwd, path))
    end)
  end

  defp exec_mix(tool, args, cwd) do
    case System.cmd("mix", [tool | args], cd: cwd, stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {output, _code} -> {:ok, output}
    end
  rescue
    e -> {:error, "Failed to execute mix #{tool}: #{Exception.message(e)}"}
  end

  defp exec_java_compile(cwd) do
    mvnw = Path.join(cwd, "mvnw")
    gradlew = Path.join(cwd, "gradlew")

    cond do
      File.exists?(mvnw) ->
        case System.cmd(Path.expand(mvnw), ["test-compile", "-q"],
               cd: cwd,
               stderr_to_stdout: true
             ) do
          {"", 0} -> {:ok, "Java compilation succeeded (0 errors)."}
          {out, 0} -> {:ok, "Java compilation succeeded:\n" <> out}
          {err, _} -> {:error, "Java compilation failed:\n" <> err}
        end

      File.exists?(Path.join(cwd, "pom.xml")) and System.find_executable("mvn") ->
        case System.cmd("mvn", ["test-compile", "-q"], cd: cwd, stderr_to_stdout: true) do
          {"", 0} -> {:ok, "Java compilation succeeded (0 errors)."}
          {out, 0} -> {:ok, "Java compilation succeeded:\n" <> out}
          {err, _} -> {:error, "Java compilation failed:\n" <> err}
        end

      File.exists?(gradlew) ->
        case System.cmd(Path.expand(gradlew), ["compileJava", "compileTestJava", "-q"],
               cd: cwd,
               stderr_to_stdout: true
             ) do
          {"", 0} -> {:ok, "Java compilation succeeded (0 errors)."}
          {out, 0} -> {:ok, "Java compilation succeeded:\n" <> out}
          {err, _} -> {:error, "Java compilation failed:\n" <> err}
        end

      File.exists?(Path.join(cwd, "build.gradle")) and System.find_executable("gradle") ->
        case System.cmd("gradle", ["compileJava", "compileTestJava", "-q"],
               cd: cwd,
               stderr_to_stdout: true
             ) do
          {"", 0} -> {:ok, "Java compilation succeeded (0 errors)."}
          {out, 0} -> {:ok, "Java compilation succeeded:\n" <> out}
          {err, _} -> {:error, "Java compilation failed:\n" <> err}
        end

      true ->
        {:error, "No Java build tool (mvnw, mvn, gradlew, gradle) found in #{cwd}."}
    end
  rescue
    e -> {:error, "Failed to run Java compilation: #{Exception.message(e)}"}
  end

  defp exec_mvn(args, cwd) do
    mvnw = Path.join(cwd, "mvnw")

    {cmd, final_args} =
      if File.exists?(mvnw) do
        {Path.expand(mvnw), args}
      else
        {"mvn", args}
      end

    try do
      case System.cmd(cmd, final_args, cd: cwd, stderr_to_stdout: true) do
        {output, 0} -> {:ok, output}
        {output, _code} -> {:error, output}
      end
    rescue
      e -> {:error, "Failed to execute #{cmd}: #{Exception.message(e)}"}
    end
  end

  defp filter_target_args(["project" | rest]), do: rest
  defp filter_target_args(rest), do: rest

  defp exec_cargo(args, cwd) do
    cond do
      not File.exists?(Path.join(cwd, "Cargo.toml")) ->
        {:error, "No Cargo.toml found in #{cwd}."}

      not is_binary(System.find_executable("cargo")) ->
        {:error, "cargo executable not found on PATH."}

      true ->
        case System.cmd("cargo", args, cd: cwd, stderr_to_stdout: true) do
          {output, 0} -> {:ok, output}
          {output, _code} -> {:error, output}
        end
    end
  rescue
    e -> {:error, "Failed to run cargo: #{Exception.message(e)}"}
  end

  defp exec_go(args, cwd) do
    cond do
      not File.exists?(Path.join(cwd, "go.mod")) ->
        {:error, "No go.mod found in #{cwd}."}

      not is_binary(System.find_executable("go")) ->
        {:error, "go executable not found on PATH."}

      true ->
        case System.cmd("go", args, cd: cwd, stderr_to_stdout: true) do
          {output, 0} ->
            if String.trim(output) == "",
              do: {:ok, "go vet succeeded (0 issues)."},
              else: {:ok, output}

          {output, _code} ->
            {:error, output}
        end
    end
  rescue
    e -> {:error, "Failed to run go: #{Exception.message(e)}"}
  end

  defp exec_metacredo(rest, cwd) do
    if Code.ensure_loaded?(Ragex.Analysis.MetaCredo) do
      params = build_metacredo_params(rest, cwd)

      case Ragex.Analysis.MetaCredo.run(params) do
        {:ok, report} ->
          {:ok, format_metacredo_report(report)}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, "Ragex.Analysis.MetaCredo is not available in this build."}
    end
  rescue
    e -> {:error, "Failed to run MetaCredo: #{Exception.message(e)}"}
  end

  defp build_metacredo_params(rest, cwd) do
    {mode, target_args} = parse_mode(rest)
    {flags, positional} = parse_metacredo_flags(target_args)
    expanded_cwd = Path.expand(cwd)

    base_params =
      case mode do
        :project ->
          metacredo_project_params(expanded_cwd, positional)

        :diff ->
          target_ref = Enum.at(positional, 0)

          %{"path" => expanded_cwd, "diff" => true, "format" => "detailed"}
          |> maybe_put_param("base", target_ref)

        :cr ->
          base_ref = Enum.at(positional, 0) || Yoke.Git.default_base_branch(cwd)
          head_ref = Enum.at(positional, 1) || "HEAD"

          %{
            "path" => expanded_cwd,
            "diff" => true,
            "base" => base_ref,
            "head" => head_ref,
            "diff_lines" => true,
            "format" => "detailed"
          }

        :custom_args ->
          metacredo_project_params(expanded_cwd, positional)
      end

    base_params
    |> maybe_put_metacredo_config(expanded_cwd)
    |> Map.merge(flags)
  end

  defp metacredo_project_params(expanded_cwd, []) do
    if expanded_cwd == File.cwd!() do
      %{"path" => expanded_cwd, "format" => "detailed"}
    else
      roots =
        MetaCredo.Config.default_included_paths()
        |> Enum.map(&Path.join(expanded_cwd, &1))
        |> Enum.filter(&File.exists?/1)

      files = if roots == [], do: [expanded_cwd], else: roots
      %{"path" => expanded_cwd, "files" => files, "format" => "detailed"}
    end
  end

  defp metacredo_project_params(expanded_cwd, [single]) do
    %{"path" => Path.expand(single, expanded_cwd), "format" => "detailed"}
  end

  defp metacredo_project_params(expanded_cwd, files) do
    %{"path" => expanded_cwd, "files" => files, "format" => "detailed"}
  end

  defp maybe_put_metacredo_config(params, expanded_cwd) do
    cfg = Path.join(expanded_cwd, ".metacredo.exs")

    if File.regular?(cfg),
      do: Map.put(params, "config", cfg),
      else: params
  end

  defp parse_metacredo_flags(args), do: parse_metacredo_flags(args, %{}, [])

  defp parse_metacredo_flags([], flags, pos), do: {flags, Enum.reverse(pos)}

  defp parse_metacredo_flags(["--strict" | rest], flags, pos),
    do: parse_metacredo_flags(rest, Map.put(flags, "strict", true), pos)

  defp parse_metacredo_flags(["--diff-lines" | rest], flags, pos),
    do: parse_metacredo_flags(rest, Map.put(flags, "diff_lines", true), pos)

  defp parse_metacredo_flags(["--no-db" | rest], flags, pos),
    do: parse_metacredo_flags(rest, Map.put(flags, "no_db", true), pos)

  defp parse_metacredo_flags(["--no-user" | rest], flags, pos),
    do: parse_metacredo_flags(rest, Map.put(flags, "no_user", true), pos)

  defp parse_metacredo_flags(["--min-confidence", val | rest], flags, pos),
    do: parse_metacredo_flags(rest, Map.put(flags, "min_confidence", val), pos)

  defp parse_metacredo_flags(["--only", val | rest], flags, pos),
    do: parse_metacredo_flags(rest, Map.put(flags, "only", val), pos)

  defp parse_metacredo_flags(["--ignore", val | rest], flags, pos),
    do: parse_metacredo_flags(rest, Map.put(flags, "ignore", val), pos)

  defp parse_metacredo_flags([other | rest], flags, pos),
    do: parse_metacredo_flags(rest, flags, [other | pos])

  defp maybe_put_param(map, _key, nil), do: map
  defp maybe_put_param(map, _key, ""), do: map
  defp maybe_put_param(map, key, val), do: Map.put(map, key, val)

  defp format_metacredo_report(%{partial: true}) do
    "MetaCredo: No changed source files found in diff (partial result)."
  end

  defp format_metacredo_report(%{total: 0, files_analyzed: files_count}) do
    "MetaCredo: No issues found across #{files_count} file(s)."
  end

  defp format_metacredo_report(%{total: total, files_analyzed: files_count, issues: issues}) do
    header = "MetaCredo: #{total} issue(s) across #{files_count} file(s):"

    lines =
      Enum.map(issues, fn issue ->
        file = issue.file || "unknown"
        line = issue.line || 1
        col = if issue.column, do: ":#{issue.column}", else: ""
        sev = issue.severity |> to_string() |> String.upcase()
        "#{file}:#{line}#{col} [#{sev}] #{issue.check}: #{issue.message}"
      end)

    Enum.join([header | lines], "\n")
  end

  defp exec_prisma(rest, cwd) do
    if Code.ensure_loaded?(Ragex.Analysis.Prisma) do
      expanded_cwd = Path.expand(cwd)

      case rest do
        ["build" | _] ->
          case Ragex.Analysis.Prisma.build(expanded_cwd) do
            {:ok, output} -> {:ok, output}
            {:error, reason} -> {:error, "Prisma build failed: #{inspect(reason)}"}
          end

        _ ->
          opts = parse_prisma_opts(rest)

          case Ragex.Analysis.Prisma.analyze(expanded_cwd, opts) do
            {:ok, findings} ->
              {:ok, format_prisma_report(findings)}

            {:error, :unavailable} ->
              {:error,
               "Prisma is not available for '#{expanded_cwd}'. Add `{:prisma, \"~> 0.2\", only: [:dev, :test], runtime: false}` to mix.exs and run `mix prisma.build`."}

            {:error, reason} ->
              {:error, "Prisma analysis failed: #{inspect(reason)}"}
          end
      end
    else
      {:error, "Ragex.Analysis.Prisma is not available in this build."}
    end
  rescue
    e -> {:error, "Failed to run Prisma: #{Exception.message(e)}"}
  end

  defp parse_prisma_opts(args), do: parse_prisma_opts(args, [])

  defp parse_prisma_opts([], acc), do: Enum.reverse(acc)

  defp parse_prisma_opts(["project" | rest], acc), do: parse_prisma_opts(rest, acc)

  defp parse_prisma_opts(["--mode", mode | rest], acc)
       when mode in ["hybrid", "gradual", "discrepancy"] do
    parse_prisma_opts(rest, [{:mode, String.to_existing_atom(mode)} | acc])
  end

  defp parse_prisma_opts(["--no-oxbow" | rest], acc),
    do: parse_prisma_opts(rest, [{:oxbow, false} | acc])

  defp parse_prisma_opts(["--warnings-as-errors" | rest], acc),
    do: parse_prisma_opts(rest, [{:warnings_as_errors, true} | acc])

  defp parse_prisma_opts([_other | rest], acc), do: parse_prisma_opts(rest, acc)

  defp format_prisma_report([]) do
    "Prisma: No findings."
  end

  defp format_prisma_report(findings) when is_list(findings) do
    header = "Prisma: #{length(findings)} finding(s):"

    lines =
      Enum.map(findings, fn f ->
        file = f.file || f.module || "unknown"
        line = if f.line, do: ":#{f.line}", else: ""
        sev = f.severity |> to_string() |> String.upcase()
        kind = f.kind || "issue"
        "#{file}#{line} [#{sev}] (#{kind}) #{f.message}"
      end)

    Enum.join([header | lines], "\n")
  end

  def help_text do
    """
    Usage: /linter [fix] <tool> [project | diff [ref] | cr [base] [head] | <args>]

    Available External Tools:
      • metacredo (aliases: meta_credo, meta-credo) - Cross-language static analysis across Elixir, Go, JS/TS, Rust, Python, Ruby, etc. (https://hexdocs.pm/metacredo)
      • oeditus_credo (aliases: oeditus, oeditus-credo) - CWE security checks & Phoenix anti-patterns (https://oeditus_credo.hexdocs.pm)
      • propwise - Property-based testing candidate detector (https://propwise.hexdocs.pm)
      • credo - Standard Credo static analyzer
      • dialyzer - Dialyxir static type checker
      • prisma - Hybrid success/gradual type analyzer for compiled beams (https://prisma.hexdocs.pm)
      • javac / mvn / checkstyle - Java compilation and style checks
      • cargo / clippy - Rust type-checking (`cargo check`) and linting (`cargo clippy`)
      • go (aliases: go_vet, golang) - Go static analysis (`go vet ./...`)
      • all - Run all tools sequentially

    Examples:
      /linter credo                          (run credo on entire project)
      /linter fix credo                      (interactively review & approve proposed diff fixes for Credo)
      /linter fix credo diff                 (interactively fix Credo findings on active git working tree diff)
      /linter fix credo cr main              (interactively fix Credo findings on PR/branch diff against main)
      /linter fix oeditus_credo cr main      (interactively fix security/anti-pattern findings on PR branch)
      /linter fix all cr main                (interactively review & approve diff fixes across all tools for a PR)
      /linter propwise cr main               (run propwise on files changed against main)
    """
  end
end
