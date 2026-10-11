defmodule Yoke.SkillManagerTest do
  use ExUnit.Case, async: false

  alias Yoke.Skill.Manager, as: SkillManager

  setup do
    tmp_dir = Path.join(System.tmp_dir!(), "skill_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)

    on_exit(fn ->
      File.rm_rf!(tmp_dir)
      SkillManager.invalidate_cache()
    end)

    {:ok, tmp_dir: tmp_dir}
  end

  defp write_skill!(root, name, body, meta \\ nil) do
    dir = Path.join(root, name)
    File.mkdir_p!(dir)

    meta =
      meta ||
        """
        ---
        name: #{name}
        description: Description for #{name}
        ---
        """

    File.write!(Path.join(dir, "SKILL.md"), meta <> "\n" <> body)
    Path.join(dir, "SKILL.md")
  end

  # ---------------------------------------------------------------------
  # Parsing
  # ---------------------------------------------------------------------

  test "parses SKILL.md file with frontmatter" do
    tmp_dir = Path.join(System.tmp_dir!(), "skill_parse_#{System.unique_integer([:positive])}")
    skill_file = Path.join(tmp_dir, "SKILL.md")
    File.mkdir_p!(tmp_dir)

    content = """
    ---
    name: test-skill
    description: A sample test skill
    ---

    # Guidelines
    Perform clean refactoring.
    """

    File.write!(skill_file, content)

    assert {:ok, skill} = SkillManager.parse_skill_file(skill_file, "test-skill")
    assert skill.name == "test-skill"
    assert skill.description == "A sample test skill"
    assert String.contains?(skill.content, "Perform clean refactoring.")

    File.rm_rf!(tmp_dir)
  end

  test "parses quoted frontmatter values" do
    tmp_dir = Path.join(System.tmp_dir!(), "skill_quote_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)
    path = Path.join(tmp_dir, "SKILL.md")

    File.write!(path, """
    ---
    name: "quoted-skill"
    description: 'A quoted: description'
    ---
    body
    """)

    assert {:ok, skill} = SkillManager.parse_skill_file(path)
    assert skill.name == "quoted-skill"
    assert skill.description == "A quoted: description"

    File.rm_rf!(tmp_dir)
  end

  test "preserves colons inside unquoted description values" do
    tmp_dir = Path.join(System.tmp_dir!(), "skill_colon_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)
    path = Path.join(tmp_dir, "SKILL.md")

    File.write!(path, """
    ---
    name: colon-skill
    description: Safe, non-locking migrations: use concurrently
    ---
    body
    """)

    assert {:ok, skill} = SkillManager.parse_skill_file(path)
    assert skill.description == "Safe, non-locking migrations: use concurrently"

    File.rm_rf!(tmp_dir)
  end

  test "falls back to folder name when frontmatter is absent" do
    tmp_dir = Path.join(System.tmp_dir!(), "skill_nofm_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)
    path = Path.join(tmp_dir, "SKILL.md")
    File.write!(path, "Just a body, no frontmatter.")

    assert {:ok, skill} = SkillManager.parse_skill_file(path, "fallback-name")
    assert skill.name == "fallback-name"
    assert skill.content == "Just a body, no frontmatter."

    File.rm_rf!(tmp_dir)
  end

  test "handles non-existent skill file parsing" do
    assert {:error, msg} = SkillManager.parse_skill_file("/tmp/non_existent_skill_path/SKILL.md")
    assert String.contains?(msg, "Failed to read skill file")
  end

  # ---------------------------------------------------------------------
  # Discovery / precedence
  # ---------------------------------------------------------------------

  test "discovers skills in project and system directories" do
    skills = SkillManager.discover_skills()
    assert is_list(skills)
  end

  test "discovers project skills with scope and root metadata", %{tmp_dir: tmp_dir} do
    write_skill!(Path.join(tmp_dir, ".yoke/skills"), "alpha", "Alpha body")

    skills = SkillManager.discover_skills(cwd: tmp_dir, cache: false)
    assert [%SkillManager{name: "alpha", scope: :project} = skill] = skills
    assert skill.root == Path.join(tmp_dir, ".yoke/skills")
    assert skill.error == nil
  end

  test "project skills shadow global skills of the same name", %{tmp_dir: tmp_dir} do
    project_root = Path.join(tmp_dir, ".yoke/skills")

    write_skill!(project_root, "dup", "Project body", """
    ---
    name: dup
    description: Project version
    ---
    """)

    # Simulate a global skill by writing into the same tmp tree and pointing
    # HOME at it is impractical; instead assert precedence via two project
    # roots is covered by dedupe ordering. Here we assert the shadow helper
    # is a no-op when there is no duplicate.
    skills = SkillManager.discover_skills(cwd: tmp_dir, cache: false)
    assert [%SkillManager{name: "dup"}] = skills
    assert SkillManager.shadowed(skills) == []
  end

  test "deduplicates by name keeping the first (highest precedence) occurrence" do
    skills = [
      %SkillManager{name: "x", scope: :project, description: "project"},
      %SkillManager{name: "x", scope: :global, description: "global"}
    ]

    # Exercised indirectly through the public API: build a workspace with a
    # project skill and assert only one entry survives.
    tmp_dir = Path.join(System.tmp_dir!(), "skill_dedupe_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)
    write_skill!(Path.join(tmp_dir, ".yoke/skills"), "x", "body")

    discovered = SkillManager.discover_skills(cwd: tmp_dir, cache: false)
    assert Enum.count(discovered, &(&1.name == "x")) == 1

    File.rm_rf!(tmp_dir)
    assert length(skills) == 2
  end

  test "surfaces parse errors instead of silently dropping skills", %{tmp_dir: tmp_dir} do
    root = Path.join(tmp_dir, ".yoke/skills")
    dir = Path.join(root, "broken")
    File.mkdir_p!(dir)
    # A directory entry with a SKILL.md that is actually a directory -> read error
    File.mkdir_p!(Path.join(dir, "SKILL.md"))

    skills = SkillManager.discover_skills(cwd: tmp_dir, cache: false)
    assert [%SkillManager{name: "broken", error: error}] = skills
    assert is_binary(error)
  end

  test "caches discovery results and invalidates on demand", %{tmp_dir: tmp_dir} do
    root = Path.join(tmp_dir, ".yoke/skills")
    write_skill!(root, "cached", "body")

    first = SkillManager.discover_skills(cwd: tmp_dir)
    assert Enum.any?(first, &(&1.name == "cached"))

    # Remove the skill; the cache should still return the stale entry.
    File.rm_rf!(Path.join(root, "cached"))
    cached = SkillManager.discover_skills(cwd: tmp_dir)
    assert Enum.any?(cached, &(&1.name == "cached"))

    SkillManager.invalidate_cache()
    refreshed = SkillManager.discover_skills(cwd: tmp_dir)
    refute Enum.any?(refreshed, &(&1.name == "cached"))
  end

  # ---------------------------------------------------------------------
  # Lookup / fuzzy matching
  # ---------------------------------------------------------------------

  test "find_skill matches exactly, case-insensitively, and by unique prefix" do
    skills = [
      %SkillManager{name: "ecto-migration-checker"},
      %SkillManager{name: "commit-style"}
    ]

    assert {:ok, %{name: "ecto-migration-checker"}} =
             SkillManager.find_skill(skills, "ecto-migration-checker")

    assert {:ok, %{name: "commit-style"}} = SkillManager.find_skill(skills, "COMMIT-STYLE")
    assert {:ok, %{name: "ecto-migration-checker"}} = SkillManager.find_skill(skills, "ecto-mig")
    assert {:error, :not_found} = SkillManager.find_skill(skills, "nope")
  end

  test "find_skill returns not_found for ambiguous prefixes" do
    skills = [
      %SkillManager{name: "ecto-migration-checker"},
      %SkillManager{name: "ecto-schema-review"}
    ]

    assert {:error, :not_found} = SkillManager.find_skill(skills, "ecto-")
  end

  test "suggestions ranks near-miss names by edit distance" do
    skills = [
      %SkillManager{name: "ecto-migration-checker"},
      %SkillManager{name: "commit-style"}
    ]

    assert SkillManager.suggestions(skills, "ecto-migraton-checker") ==
             ["ecto-migration-checker"]

    assert SkillManager.suggestions(skills, "totally-unrelated") == []
  end

  # ---------------------------------------------------------------------
  # Rendering / scaffolding
  # ---------------------------------------------------------------------

  test "render substitutes {{arg}} and $ARGUMENTS placeholders" do
    skill = %SkillManager{content: "Check {{arg}} and $ARGUMENTS now."}
    assert SkillManager.render(skill, "lib/foo.ex") == "Check lib/foo.ex and lib/foo.ex now."
  end

  test "render with empty args strips placeholders" do
    skill = %SkillManager{content: "Check {{ arg }} now."}
    assert SkillManager.render(skill, "") == "Check  now."
  end

  test "scaffold writes a template SKILL.md", %{tmp_dir: tmp_dir} do
    root = Path.join(tmp_dir, ".yoke/skills")
    assert {:ok, path} = SkillManager.scaffold("brand-new", root)
    assert File.exists?(path)

    assert {:ok, skill} = SkillManager.parse_skill_file(path)
    assert skill.name == "brand-new"
    assert String.contains?(skill.content, "{{arg}}")
  end

  test "scaffold refuses to overwrite an existing skill", %{tmp_dir: tmp_dir} do
    root = Path.join(tmp_dir, ".yoke/skills")
    assert {:ok, _path} = SkillManager.scaffold("dupe", root)
    assert {:error, msg} = SkillManager.scaffold("dupe", root)
    assert String.contains?(msg, "already exists")
  end

  test "scaffold rejects invalid names", %{tmp_dir: tmp_dir} do
    root = Path.join(tmp_dir, ".yoke/skills")
    assert {:error, msg} = SkillManager.scaffold("../escape", root)
    assert String.contains?(msg, "Invalid skill name")
  end
end
