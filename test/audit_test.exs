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
      assert facts.hygiene.quality_gates == ["quality"]
    end

    test "detects a source file with no matching test file", %{dir: dir} do
      facts = Audit.collect(dir)
      # bar.ex has bar_test.exs; baz.ex does not.
      assert "lib/foo/baz.ex" in facts.health.untested_files
      refute "lib/foo/bar.ex" in facts.health.untested_files
    end

    test "matches the full relative path, not just the basename", %{dir: dir} do
      # A test file with the right basename but the wrong directory must not
      # count as coverage for a source file elsewhere in the tree. Matching
      # basenames alone reported `lib/foo/baz.ex` as covered by this file.
      File.mkdir_p!(Path.join(dir, "test/other"))
      File.write!(Path.join(dir, "test/other/baz_test.exs"), "defmodule Other.BazTest do\nend\n")

      facts = Audit.collect(dir)
      assert "lib/foo/baz.ex" in facts.health.untested_files
    end

    test "a mirrored test path counts as coverage", %{dir: dir} do
      # `lib/foo/nested/deep.ex` is covered by `test/foo/nested/deep_test.exs`
      # even though no other module shares its basename.
      File.mkdir_p!(Path.join(dir, "lib/foo/nested"))
      File.mkdir_p!(Path.join(dir, "test/foo/nested"))
      File.write!(Path.join(dir, "lib/foo/nested/deep.ex"), "defmodule Foo.Nested.Deep do\nend\n")

      File.write!(
        Path.join(dir, "test/foo/nested/deep_test.exs"),
        "defmodule Foo.Nested.DeepTest do\nend\n"
      )

      facts = Audit.collect(dir)
      refute "lib/foo/nested/deep.ex" in facts.health.untested_files
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

  describe "Rust workspace audit" do
    setup do
      dir = Path.join(System.tmp_dir!(), "yoke_audit_rust_#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(dir, "crates/core/src"))
      File.mkdir_p!(Path.join(dir, "crates/core/tests"))
      File.mkdir_p!(Path.join(dir, "target/debug"))

      File.write!(Path.join(dir, "Cargo.toml"), """
      [workspace]
      members = ["crates/core"]

      [workspace.lints.clippy]
      all = "warn"
      """)

      File.write!(Path.join(dir, "Cargo.lock"), "# lockfile\n")
      File.write!(Path.join(dir, "justfile"), "check:\n\tcargo clippy\n")

      File.write!(Path.join(dir, "crates/core/src/lib.rs"), """
      pub fn add(a: i32, b: i32) -> i32 {
          // TODO: handle overflow
          a + b
      }

      #[cfg(test)]
      mod tests {
          #[test]
          fn works() {
              assert_eq!(super::add(1, 2), 3);
          }
      }
      """)

      File.write!(Path.join(dir, "crates/core/tests/integration.rs"), """
      #[test]
      fn integration_works() {
          // TODO: test fixture, not a real task
          assert_eq!(2 + 2, 4);
      }
      """)

      File.write!(Path.join(dir, "target/debug/generated.rs"), "fn ignored() {}\n")

      on_exit(fn -> File.rm_rf!(dir) end)
      {:ok, rust_dir: dir}
    end

    test "counts workspace crates, integration tests, and inline tests", %{rust_dir: dir} do
      facts = Audit.collect(dir)

      assert facts.shape.languages == ["rust"]
      assert facts.shape.source_file_count == 1
      assert facts.shape.test_file_count == 1
      assert facts.shape.inline_tested_count == 1
      assert facts.shape.source_lines > 0

      assert facts.hygiene.has_lockfile == true
      assert facts.hygiene.has_formatter == true
      assert "Cargo.toml [lints]" in facts.hygiene.quality_gates
      assert "justfile" in facts.hygiene.quality_gates

      # Integration test markers are excluded just like Elixir test/ markers.
      assert length(facts.markers) == 1
      assert hd(facts.markers).file == "crates/core/src/lib.rs"
    end

    test "renders Rust-appropriate hygiene without Elixir-only labels", %{rust_dir: dir} do
      md = dir |> Audit.collect() |> Audit.format_facts()

      assert md =~ "Formatter (rustfmt)"
      assert md =~ "Linter (clippy)"
      assert md =~ "Inline-tested source files: 1"
      refute md =~ "Credo"
      refute md =~ "Dialyzer"
      refute md =~ "Quality aliases in mix.exs"
      refute md =~ "every source file has a matching test file"
    end
  end

  describe "Go project audit" do
    setup do
      dir = Path.join(System.tmp_dir!(), "yoke_audit_go_#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(dir, "pkg/math"))

      File.write!(Path.join(dir, "go.mod"), "module example.com/demo\n")
      File.write!(Path.join(dir, "go.sum"), "")

      File.write!(
        Path.join(dir, "pkg/math/add.go"),
        "package math\nfunc Add(a, b int) int { return a + b }\n"
      )

      File.write!(Path.join(dir, "pkg/math/add_test.go"), "package math\n")

      File.write!(
        Path.join(dir, "pkg/math/sub.go"),
        "package math\nfunc Sub(a, b int) int { return a - b }\n"
      )

      on_exit(fn -> File.rm_rf!(dir) end)
      {:ok, go_dir: dir}
    end

    test "separates *_test.go from source files and maps sibling tests", %{go_dir: dir} do
      facts = Audit.collect(dir)

      assert facts.shape.languages == ["go"]
      assert facts.shape.source_file_count == 2
      assert facts.shape.test_file_count == 1
      assert facts.health.supports_sibling_tests? == true
      assert facts.health.untested_files == ["pkg/math/sub.go"]
    end
  end

  describe ".yoke/config.json audit overrides" do
    test "overrides globs, ignore_dirs, and hygiene tools per project" do
      dir = Path.join(System.tmp_dir!(), "yoke_audit_cfg_#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(dir, ".yoke"))
      File.mkdir_p!(Path.join(dir, "custom_src/generated"))
      File.mkdir_p!(Path.join(dir, "custom_tests"))

      File.write!(Path.join(dir, "custom_src/main.xyz"), "fn main() {}\n")
      File.write!(Path.join(dir, "custom_src/generated/skip.xyz"), "fn skip() {}\n")
      File.write!(Path.join(dir, "custom_tests/main_test.xyz"), "fn test_main() {}\n")
      File.write!(Path.join(dir, ".xyzfmt"), "")
      File.write!(Path.join(dir, "Taskfile.yml"), "version: '3'\n")

      File.write!(
        Path.join(dir, ".yoke/config.json"),
        Yoke.Json.encode!(%{
          "audit" => %{
            "languages" => ["xyz"],
            "source_globs" => ["custom_src/**/*.xyz"],
            "test_globs" => ["custom_tests/**/*.xyz"],
            "ignore_dirs" => ["generated"],
            "hygiene" => %{
              "formatter" => [".xyzfmt"],
              "quality_gates" => ["Taskfile.yml"]
            }
          }
        })
      )

      on_exit(fn -> File.rm_rf!(dir) end)

      facts = Audit.collect(dir)
      assert facts.shape.languages == ["xyz"]
      assert facts.shape.source_file_count == 1
      assert facts.shape.test_file_count == 1
      assert facts.hygiene.has_formatter == true
      assert "Taskfile.yml" in facts.hygiene.quality_gates
    end
  end

  describe "nested project roots" do
    setup do
      root =
        Path.join(System.tmp_dir!(), "yoke_audit_nested_#{System.unique_integer([:positive])}")

      app = Path.join(root, "app")
      File.mkdir_p!(Path.join(app, "lib"))
      File.mkdir_p!(Path.join(app, "test"))

      File.write!(Path.join(app, "mix.exs"), """
      defmodule AuditExample.MixProject do
        use Mix.Project
        def project, do: [app: :audit_example, version: "0.1.0"]
      end
      """)

      File.write!(Path.join(app, ".formatter.exs"), "[inputs: [\"{lib,test}/**/*.{ex,exs}\"]]\n")
      File.write!(Path.join(app, "lib/example.ex"), "defmodule AuditExample do\nend\n")
      File.write!(Path.join(app, "test/example_test.exs"), "defmodule AuditExampleTest do\nend\n")

      on_exit(fn -> File.rm_rf!(root) end)
      {:ok, root: root, app: app}
    end

    test "a container directory redirects the audit to its single nested project",
         %{root: root, app: app} do
      facts = Audit.collect(root)

      assert facts.cwd == app
      assert facts.scope.root == app
      assert facts.scope.requested == root
      assert facts.scope.redirected? == true
      assert facts.scope.reason == :nested_project

      assert facts.shape.source_file_count == 1
      assert facts.shape.test_file_count == 1
      assert facts.hygiene.has_formatter == true
    end

    test "the redirected audit explains itself in the facts and the header",
         %{root: root} do
      facts = Audit.collect(root)

      assert Audit.format_facts(facts) =~ "**Scope**"
      assert Audit.format_facts(facts) =~ "redirected from"
      assert Audit.format_header(facts) =~ "auditing the nested project instead"
    end

    test "an explicit root wins over nested detection", %{root: root, app: app} do
      facts = Audit.collect(root, root: app)

      assert facts.cwd == app
      assert facts.scope.redirected? == true
      assert facts.scope.reason == :explicit
    end

    test "allow_nested_root keeps the requested directory", %{root: root} do
      facts = Audit.collect(root, allow_nested_root: true)

      assert facts.cwd == root
      assert facts.scope.redirected? == false
      assert facts.shape.source_file_count == 0
    end

    test "several nested projects are reported instead of guessed", %{root: root} do
      other = Path.join(root, "other")
      File.mkdir_p!(Path.join(other, "lib"))
      File.write!(Path.join(other, "mix.exs"), "[]\n")

      facts = Audit.collect(root)

      assert facts.cwd == root
      assert facts.scope.redirected? == false
      assert facts.scope.reason == :ambiguous_nested_projects
      assert length(facts.scope.nested_roots) == 2

      rendered = Audit.format_facts(facts)
      assert rendered =~ "none was chosen"
      assert rendered =~ "--root <dir>"
    end

    test "an empty directory is scope information, not a clean bill of health" do
      empty =
        Path.join(System.tmp_dir!(), "yoke_audit_bare_#{System.unique_integer([:positive])}")

      File.mkdir_p!(empty)
      on_exit(fn -> File.rm_rf!(empty) end)

      facts = Audit.collect(empty)
      rendered = Audit.format_facts(facts)

      assert facts.shape.source_file_count == 0
      assert facts.scope.reason == :no_project
      assert Enum.any?(facts.notes, &(&1 =~ "not a healthy project"))
      assert rendered =~ "not a clean-project assessment"

      # A zero-file scan must never claim every source file is tested.
      refute rendered =~ "every source file has a matching test file"
    end

    test "an untracked directory does not report a clean working tree", %{app: app} do
      facts = Audit.collect(app)

      assert facts.health.git_tracked? == false
      assert Audit.format_facts(facts) =~ "not a Git repository"
    end
  end
end
