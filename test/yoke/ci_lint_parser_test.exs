defmodule Yoke.CI.Lint.ParserTest do
  use ExUnit.Case, async: true

  alias Yoke.CI.Lint.Parser

  describe "credo" do
    test "parses the JSON issue schema" do
      output =
        Yoke.Json.encode!(%{
          "issues" => [
            %{
              "category" => "refactoring",
              "check" => "Credo.Check.Refactoring.PreferForComprehension",
              "filename" => "lib/foo.ex",
              "line_no" => 42,
              "message" => "Prefer a comprehension",
              "priority" => 4
            }
          ]
        })

      assert [finding] = Parser.parse("credo", output)
      assert finding.file == "lib/foo.ex"
      assert finding.line == 42
      assert finding.title == "PreferForComprehension"
      assert finding.description == "Prefer a comprehension"
      # Credo priority 4 is the lowest, which maps to `info`.
      assert finding.severity == "info"
      assert finding.kind == "issue"
    end

    test "maps every priority onto a severity" do
      for {priority, severity} <- [{1, "high"}, {2, "medium"}, {3, "low"}, {4, "info"}] do
        output =
          Yoke.Json.encode!(%{
            "issues" => [
              %{"check" => "X.Y", "filename" => "a.ex", "line_no" => 1, "priority" => priority}
            ]
          })

        assert [finding] = Parser.parse("credo", output)
        assert finding.severity == severity, "priority #{priority} should be #{severity}"
      end
    end

    test "oeditus_credo shares the schema" do
      output =
        Yoke.Json.encode!(%{
          "issues" => [
            %{
              "check" => "OeditusCredo.Check.Foo",
              "filename" => "b.ex",
              "line_no" => 7,
              "priority" => 2
            }
          ]
        })

      assert [finding] = Parser.parse("oeditus_credo", output)
      assert finding.file == "b.ex"
      assert finding.severity == "medium"
    end

    test "returns no findings for a clean run" do
      assert Parser.parse("credo", ~s({"issues": []})) == []
    end

    test "returns no findings for unparseable output rather than raising" do
      assert Parser.parse("credo", "not json at all") == []
      assert Parser.parse("credo", "") == []
      assert Parser.parse("credo", ~s({"issues": "wrong type"})) == []
    end

    test "tolerates a missing check name" do
      output = Yoke.Json.encode!(%{"issues" => [%{"filename" => "a.ex", "line_no" => 1}]})
      assert [finding] = Parser.parse("credo", output)
      assert finding.title == "credo"
    end

    test "tolerates a missing filename and line" do
      output = Yoke.Json.encode!(%{"issues" => [%{"check" => "A.B", "priority" => 1}]})
      assert [finding] = Parser.parse("credo", output)
      assert finding.file == nil
      assert finding.line == nil
    end
  end

  describe "dialyzer" do
    test "parses short-format lines" do
      output = """
      lib/foo.ex:12: Function bar/1 has no local return
      lib/baz.ex:7: The pattern can never match
      """

      findings = Parser.parse("dialyzer", output)

      assert length(findings) == 2
      assert [first, second] = findings
      assert first.file == "lib/foo.ex"
      assert first.line == 12
      assert first.description == "Function bar/1 has no local return"
      assert first.severity == "high"
      assert second.file == "lib/baz.ex"
      assert second.line == 7
    end

    test "parses the variant with an error code before the message" do
      findings =
        Parser.parse("dialyzer", "lib/foo.ex:12:no_return Function bar/1 has no local return")

      assert [finding] = findings
      assert finding.file == "lib/foo.ex"
      assert finding.line == 12
      assert finding.description =~ "no local return"
    end

    test "ignores non-matching lines" do
      output = """
      Checking PLT...
      PLT is up to date!
      lib/foo.ex:12: A real warning
      """

      assert [finding] = Parser.parse("dialyzer", output)
      assert finding.file == "lib/foo.ex"
    end

    test "returns no findings for clean output" do
      assert Parser.parse("dialyzer", "PLT is up to date!\n") == []
      assert Parser.parse("dialyzer", "") == []
    end
  end

  describe "format" do
    test "parses unformatted file paths" do
      output = """
      ** (Mix) mix format failed due to --check-formatted.
      The following files are not formatted:

      lib/foo.ex
      test/bar_test.exs
      """

      findings = Parser.parse("format", output)

      assert length(findings) == 2
      assert Enum.map(findings, & &1.file) == ["lib/foo.ex", "test/bar_test.exs"]
      assert Enum.all?(findings, &(&1.severity == "low"))
    end

    test "ignores log lines and summaries" do
      output = """
      Compiling 3 files (.ex)
      Generated foo app
      lib/foo.ex
      """

      assert [finding] = Parser.parse("format", output)
      assert finding.file == "lib/foo.ex"
    end

    test "returns no findings when everything is formatted" do
      assert Parser.parse("format", "") == []
    end
  end

  describe "deps.audit" do
    test "parses advisory blocks" do
      output = """
      Name: CVE-2024-1234
      Dependency: some_lib
      Title: Remote code execution
      URL: https://example.invalid
      """

      assert [finding] = Parser.parse("deps.audit", output)
      assert finding.title == "Remote code execution"
      assert finding.description =~ "some_lib"
      assert finding.severity == "high"
      assert finding.fix_suggestion =~ "some_lib"
    end

    test "parses multiple advisories" do
      output = """
      Name: A
      Dependency: lib_a
      Title: Issue A

      Name: B
      Dependency: lib_b
      Title: Issue B
      """

      findings = Parser.parse("deps.audit", output)
      assert length(findings) == 2
      assert Enum.map(findings, & &1.title) == ["Issue A", "Issue B"]
    end

    test "returns no findings when there are no advisories" do
      assert Parser.parse("deps.audit", "No vulnerabilities found.") == []
    end
  end

  describe "propwise" do
    test "surfaces output as a single informational finding" do
      assert [finding] = Parser.parse("propwise", "Consider property tests for foo/1")
      assert finding.severity == "info"
      assert finding.description =~ "property tests"
    end

    test "returns no findings for empty output" do
      assert Parser.parse("propwise", "") == []
    end
  end

  describe "unknown tools" do
    test "return no findings" do
      assert Parser.parse("mystery", "whatever") == []
    end
  end
end
