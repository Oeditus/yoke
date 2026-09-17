defmodule Yoke.LinterTest do
  use ExUnit.Case, async: true
  alias Yoke.Linter
  alias Yoke.Linter.Fixer
  alias Yoke.Linter.Parser

  describe "list_tools/0" do
    test "returns list of available tools including oeditus_credo and propwise" do
      tools = Linter.list_tools()
      names = Enum.map(tools, & &1.name)

      assert "oeditus_credo" in names
      assert "propwise" in names
      assert "credo" in names
      assert "dialyzer" in names
      assert "all" in names
    end
  end

  describe "run/2" do
    test "returns help text on empty input or help" do
      {:ok, help1} = Linter.run("")
      {:ok, help2} = Linter.run("help")

      assert String.contains?(help1, "Usage: /linter")
      assert String.contains?(help2, "Available External Tools")
    end

    test "returns error on unknown tool" do
      {:error, err} = Linter.run("unknown_tool")
      assert String.contains?(err, "Unknown linter tool")
    end

    @tag ragex: true
    test "accepts aliases for oeditus_credo" do
      {:ok, out1} = Linter.run("oeditus_credo cr main")
      {:ok, out2} = Linter.run("oeditus cr main")
      {:ok, out3} = Linter.run("oeditus-credo cr main")

      assert is_binary(out1)
      assert is_binary(out2)
      assert is_binary(out3)
    end

    @tag ragex: true
    test "handles fix mode on diff and cr targets cleanly" do
      {:ok, out1} = Linter.run("fix credo diff")
      {:ok, out2} = Linter.run("fix credo cr main")
      assert is_binary(out1)
      assert is_binary(out2)
    end
  end

  describe "Parser.parse/2" do
    test "parses credo and dialyzer output text" do
      sample_output = """
      lib/yoke/cli/repl.ex:712:14 [C] Credo.Check.Readability.MaxLineLength: Line is too long
      lib/yoke/linter.ex:45: Dialyzer warning: Function has no local return
      """

      findings = Parser.parse(sample_output, "credo")
      assert length(findings) == 2

      f1 = Enum.at(findings, 0)
      assert f1.file == "lib/yoke/cli/repl.ex"
      assert f1.line == 712
      assert f1.column == 14
      assert f1.check == "Credo.Check.Readability.MaxLineLength"

      f2 = Enum.at(findings, 1)
      assert f2.file == "lib/yoke/linter.ex"
      assert f2.line == 45
    end

    test "parses mix format style output" do
      sample_output = "  lib/yoke/linter.ex\n"
      findings = Parser.parse(sample_output, "mix_format")
      assert length(findings) == 1

      f = Enum.at(findings, 0)
      assert f.file == "lib/yoke/linter.ex"
      assert f.check == "Mix.Format"
    end
  end

  describe "Fixer.propose_fix/2 and apply_patch/1" do
    test "generates mechanical fix diff for format issue and applies patch" do
      tmp_dir = System.tmp_dir!()
      file_path = Path.join(tmp_dir, "sample_unformatted.ex")
      unformatted_code = "defmodule Sample do\n  def foo() do   :ok end\nend\n"

      File.write!(file_path, unformatted_code)

      finding = %Parser.Finding{
        file: file_path,
        line: 1,
        column: 1,
        check: "Mix.Format",
        message: "File needs formatting with mix format",
        tool: "mix_format"
      }

      {:ok, patch} = Fixer.propose_fix(finding, "/")
      assert patch.fix_type == :mechanical
      assert String.contains?(patch.diff, "--- a/")
      assert String.contains?(patch.diff, "+++ b/")

      :ok = Fixer.apply_patch(patch)
      formatted_content = File.read!(file_path)
      assert formatted_content != unformatted_code
      assert String.contains?(formatted_content, ":ok")

      File.rm(file_path)
    end
  end
end
