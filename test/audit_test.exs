defmodule Yoke.AuditTest do
  use ExUnit.Case, async: true

  alias Yoke.Audit

  setup do
    dir = Path.join(System.tmp_dir!(), "yoke_audit_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "lib/foo"))
    File.mkdir_p!(Path.join(dir, "test/foo"))

    File.write!(Path.join(dir, "mix.exs"), """
    defmodule Demo.MixProject do
      def project, do: [aliases: [quality: ["format", "credo --strict"]]]
    end
    """)

    File.write!(Path.join(dir, "lib/foo/bar.ex"), """
    defmodule Foo.Bar do
      # TODO: handle the error case
      def run(x), do: x + 1
    end
    """)

    File.write!(Path.join(dir, "lib/foo/baz.ex"), """
    defmodule Foo.Baz do
      # FIXME: this is O(n^2)
      def slow(list), do: Enum.map(list, fn a -> Enum.count(list, &(&1 == a)) end)
    end
    """)

    File.write!(Path.join(dir, "test/foo/bar_test.exs"), "defmodule Foo.BarTest do\nend\n")

    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  describe "collect/1" do
    test "counts source and test files", %{dir: dir} do
      facts = Audit.collect(dir)

      assert facts.shape.source_file_count == 2
      assert facts.shape.test_file_count == 1
      assert facts.shape.source_lines > 0
    end

    test "lists the largest modules first", %{dir: dir} do
      facts = Audit.collect(dir)
      assert length(facts.shape.largest_modules) == 2

      lines = Enum.map(facts.shape.largest_modules, &elem(&1, 1))
      assert lines == Enum.sort(lines, :desc)
    end

    test "collects TODO/FIXME markers with file and line", %{dir: dir} do
      facts = Audit.collect(dir)

      texts = Enum.map(facts.markers, & &1.text)
      assert Enum.any?(texts, &(&1 =~ "TODO"))
      assert Enum.any?(texts, &(&1 =~ "FIXME"))

      assert Enum.all?(facts.markers, &String.starts_with?(&1.file, "lib/"))
    end

    test "ignores markers inside test files", %{dir: dir} do
      File.write!(
        Path.join(dir, "test/foo/bar_test.exs"),
        "# TODO: test fixture, not a real task\n"
      )

      facts = Audit.collect(dir)
      refute Enum.any?(facts.markers, &String.starts_with?(&1.file, "test/"))
    end

    test "reports hygiene signals", %{dir: dir} do
      facts = Audit.collect(dir)

      assert facts.hygiene.has_formatter == false
      assert facts.hygiene.has_readme == false
      assert facts.hygiene.quality_aliases == ["quality"]
    end

    test "detects a source file with no matching test file", %{dir: dir} do
      facts = Audit.collect(dir)
      # bar.ex has bar_test.exs; baz.ex does not.
      assert "lib/foo/baz.ex" in facts.health.untested_dirs
      refute "lib/foo/bar.ex" in facts.health.untested_dirs
    end

    test "computes the test-to-source ratio", %{dir: dir} do
      facts = Audit.collect(dir)
      assert facts.health.test_to_source_ratio == 0.5
    end

    test "does not crash on an empty directory" do
      empty =
        Path.join(System.tmp_dir!(), "yoke_audit_empty_#{System.unique_integer([:positive])}")

      File.mkdir_p!(empty)
      on_exit(fn -> File.rm_rf!(empty) end)

      facts = Audit.collect(empty)
      assert facts.shape.source_file_count == 0
      assert facts.shape.largest_modules == []
      assert facts.markers == []
    end

    test "ignores build and dependency directories", %{dir: dir} do
      File.mkdir_p!(Path.join(dir, "deps/some_dep/lib"))
      File.write!(Path.join(dir, "deps/some_dep/lib/dep.ex"), "defmodule Dep do end\n")
      File.mkdir_p!(Path.join(dir, "_build/dev"))
      File.write!(Path.join(dir, "_build/dev/gen.ex"), "defmodule Gen do end\n")

      facts = Audit.collect(dir)
      assert facts.shape.source_file_count == 2

      paths = Enum.map(facts.shape.largest_modules, &elem(&1, 0))
      refute Enum.any?(paths, &String.contains?(&1, "deps/"))
      refute Enum.any?(paths, &String.contains?(&1, "_build/"))
    end
  end

  describe "format_facts/1" do
    test "renders the measured facts as markdown", %{dir: dir} do
      md = dir |> Audit.collect() |> Audit.format_facts()

      assert md =~ "Project facts"
      assert md =~ "Source files: 2"
      assert md =~ "TODO"
      assert md =~ "Hygiene"
      assert md =~ "Health"
    end
  end

  describe "build_prompt/2" do
    test "asks for the four audit sections by default", %{dir: dir} do
      prompt = dir |> Audit.collect() |> Audit.build_prompt()

      assert prompt =~ "Strong parts"
      assert prompt =~ "Weaknesses & glitches to fix"
      assert prompt =~ "Codebase improvement ideas"
      assert prompt =~ "UX improvement ideas"
    end

    test "narrows to code-only sections with focus: :code", %{dir: dir} do
      prompt = dir |> Audit.collect() |> Audit.build_prompt(focus: :code)

      assert prompt =~ "Strong parts"
      assert prompt =~ "Improvement ideas"
      refute prompt =~ "UX improvement ideas"
    end

    test "narrows to UX-only sections with focus: :ux", %{dir: dir} do
      prompt = dir |> Audit.collect() |> Audit.build_prompt(focus: :ux)

      assert prompt =~ "UX improvement ideas"
      refute prompt =~ "Codebase improvement ideas"
    end

    test "embeds the measured facts and demands evidence", %{dir: dir} do
      prompt = dir |> Audit.collect() |> Audit.build_prompt()

      assert prompt =~ "Project facts"
      assert prompt =~ "Ground every claim in evidence"
    end
  end

  test "format_header/1 names the audited directory", %{dir: dir} do
    header = dir |> Audit.collect() |> Audit.format_header()
    assert header =~ "Project Audit"
    assert header =~ Path.expand(dir)
  end
end
