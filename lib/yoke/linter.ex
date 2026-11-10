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
      t when t in ["oeditus_credo", "oeditus-credo", "oeditus"] -> "oeditus_credo"
      "propwise" -> "propwise"
      "credo" -> "credo"
      "dialyzer" -> "dialyzer"
      t when t in ["javac", "java", "compile"] -> "javac"
      t when t in ["mvn", "maven"] -> "mvn"
      "checkstyle" -> "checkstyle"
      "all" -> :all
      "help" -> :unknown
      "list" -> :unknown
      _ -> :unknown
    end
  end

  defp run_all(rest, cwd) do
    tools =
      if not File.exists?(Path.join(cwd, "mix.exs")) and
           (File.exists?(Path.join(cwd, "pom.xml")) or
              File.exists?(Path.join(cwd, "build.gradle"))) do
        ["javac"]
      else
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

  def help_text do
    """
    Usage: /linter [fix] <tool> [project | diff [ref] | cr [base] [head] | <args>]

    Available External Tools:
      • oeditus_credo (aliases: oeditus, oeditus-credo) - CWE security checks & Phoenix anti-patterns (https://oeditus_credo.hexdocs.pm)
      • propwise - Property-based testing candidate detector (https://propwise.hexdocs.pm)
      • credo - Standard Credo static analyzer
      • dialyzer - Dialyxir static type checker
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
