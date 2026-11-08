defmodule Yoke.PRReview.ContextTest do
  use ExUnit.Case, async: true
  @moduletag :tmp_dir
  alias Yoke.PRReview.Context
  alias Yoke.PRReview.Tools
  alias Yoke.Test.ReviewFixture, as: Fixture

  setup %{tmp_dir: dir}, do: Fixture.repository(Path.join(dir, "repo"))

  test "pins commits and ignores checkout edits and later branch movement", %{
    repo: repo,
    head: head,
    base: base
  } do
    assert {:ok, context} = Context.resolve("main feature", repo)
    assert context.base_sha == base
    assert context.head_sha == head
    assert context.raw_diff =~ "+reviewed_value"
    File.write!(Path.join(repo, "sample.ex"), "unrelated_dirty_value\n")

    assert {:ok, "reviewed_value\n"} =
             Tools.execute("read_file", %{"path" => "sample.ex"}, context)

    assert {:ok, diff} = Tools.execute("git_diff", %{}, context)
    assert diff == context.raw_diff
    Fixture.commit(repo, "later change")

    assert {:ok, "reviewed_value\n"} =
             Tools.execute("read_file", %{"path" => "sample.ex"}, context)

    refute diff =~ "unrelated_dirty_value"
    assert {:ok, ^head} = Yoke.Git.resolve_revision(context.head_sha, repo)
  end

  test "ranges past EOF return actionable feedback, not ambiguous empty output", %{repo: repo} do
    assert {:ok, context} = Context.resolve("main feature", repo)

    for start <- [2, 100, 1000] do
      assert {:error, message} =
               Tools.execute(
                 "read_file",
                 %{"path" => "sample.ex", "start_line" => start},
                 context
               )

      assert message =~ "past end of file (1 lines)"
      assert message =~ "finish the review"
    end
  end

  test "range reads preserve real trailing blank lines and handle empty files", %{repo: repo} do
    File.write!(Path.join(repo, "sample.ex"), "value\n\n\n")
    File.write!(Path.join(repo, "empty.ex"), "")
    Fixture.commit(repo, "blank and empty files")
    assert {:ok, context} = Context.resolve("main HEAD", repo)

    assert {:ok, "2: \n3: "} =
             Tools.execute("read_file", %{"path" => "sample.ex", "start_line" => 2}, context)

    assert {:error, message} =
             Tools.execute("read_file", %{"path" => "empty.ex", "start_line" => 1}, context)

    assert message =~ "past end of file (0 lines)"
    assert {:ok, ""} = Tools.execute("read_file", %{"path" => "empty.ex"}, context)
  end

  test "rejects empty, missing, malformed and oversized review ranges", %{repo: repo} do
    File.write!(Path.join(repo, "sample.ex"), "dirty changes\n")
    assert {:error, empty} = Context.resolve("HEAD HEAD", repo)
    assert empty =~ "No committed changes"
    assert {:error, _} = Context.resolve("missing HEAD", repo)
    assert {:error, _} = Context.resolve("--help HEAD", repo)
    assert {:error, usage} = Context.resolve("main feature extra", repo)
    assert usage =~ "Usage"
    File.write!(Path.join(repo, "large.txt"), String.duplicate("large payload\n", 25_000))
    Fixture.commit(repo, "large change")
    assert {:error, large} = Context.resolve("main HEAD", repo)
    # The message must name the limit and how to raise it, not just refuse.
    assert large =~ "over the 300 KB limit"
    assert large =~ "max_diff_bytes"
  end

  test "uses merge-base semantics when base has advanced", %{repo: repo} do
    Fixture.git(repo, ["checkout", "-q", "main"])
    File.write!(Path.join(repo, "base-only.ex"), "not part of feature\n")
    Fixture.commit(repo, "base advanced")
    assert {:ok, context} = Context.resolve("main feature", repo)
    refute context.raw_diff =~ "base-only.ex"
    assert context.raw_diff =~ "reviewed_value"
  end

  test "read-only tools search the revision and reject mutation or out-of-repository reads", %{
    repo: repo
  } do
    assert {:ok, context} = Context.resolve("main feature", repo)
    File.write!(Path.join(repo, "sample.ex"), "wrong_workspace_value\n")

    for name <- ~w(bash write_file replace_file git_commit spawn_subagent mcp_ragex_edit_file) do
      assert {:error, error} = Tools.execute(name, %{"command" => "ignored"}, context)
      assert error =~ "unavailable"
    end

    assert {:error, _} = Tools.execute("read_file", %{"path" => "../outside"}, context)
    assert {:error, _} = Tools.execute("read_file", %{"path" => "/etc/passwd"}, context)

    assert {:ok, found} =
             Tools.execute(
               "grep_search",
               %{"query" => "reviewed_value", "path_pattern" => "*.ex"},
               context
             )

    assert found =~ "reviewed_value"
    refute found =~ "wrong_workspace_value"

    assert {:ok, "No matches in the reviewed revision."} =
             Tools.execute("grep_search", %{"query" => "wrong_workspace_value"}, context)

    assert {:ok, files} = Tools.execute("list_dir", %{}, context)
    assert files =~ "sample.ex"
    assert {:ok, globbed} = Tools.execute("glob_search", %{"pattern" => "**/*.ex"}, context)
    assert globbed =~ "sample.ex"

    assert {:ok, "1: reviewed_value"} =
             Tools.execute(
               "read_file",
               %{"path" => "sample.ex", "start_line" => 1, "end_line" => 1},
               context
             )
  end

  test "only findings located in reviewed hunks are accepted", %{repo: repo} do
    assert {:ok, context} = Context.resolve("main feature", repo)
    finding = %{file: "sample.ex", line: 1, title: "Regression", kind: "issue"}
    assert :ok = Context.validate_findings([finding], context)
    assert {:error, _} = Context.validate_findings([%{finding | file: "unrelated.ex"}], context)
    assert {:error, _} = Context.validate_findings([%{finding | line: 99}], context)
    assert {:error, _} = Context.validate_findings([%{finding | file: nil, line: nil}], context)
    assert {:error, _} = Context.validate_findings([%{finding | line: nil}], context)
    assert :ok = Context.validate_findings([], context)
  end

  test "deleted-file regressions can carry a file-level anchor", %{repo: repo} do
    File.rm!(Path.join(repo, "sample.ex"))
    Fixture.commit(repo, "remove file")
    assert {:ok, context} = Context.resolve("main HEAD", repo)

    assert :ok =
             Context.validate_findings(
               [%{file: "sample.ex", line: nil, title: "Deleted API", kind: "issue"}],
               context
             )

    assert {:ok, "old_value\n"} =
             Tools.execute("read_file", %{"path" => "sample.ex", "revision" => "base"}, context)

    assert {:error, _} = Tools.execute("read_file", %{"path" => "sample.ex"}, context)
  end

  test "review diff headers and lines ignore personal Git display settings", %{repo: repo} do
    for {key, value} <- [
          {"diff.noprefix", "true"},
          {"diff.mnemonicPrefix", "true"},
          {"diff.srcPrefix", "old/"},
          {"diff.dstPrefix", "new/"},
          {"diff.context", "0"},
          {"diff.relative", "true"},
          {"color.ui", "always"}
        ] do
      Fixture.git(repo, ["config", key, value])
    end

    assert {:ok, context} = Context.resolve("main feature", repo)
    assert context.raw_diff =~ "+++ b/sample.ex"
    assert MapSet.member?(context.valid_lines, {"sample.ex", 1})
    refute context.raw_diff =~ "\e["
  end

  test "submodule paths and hunks use the same ignore overrides", %{repo: repo, head: head} do
    Fixture.git(repo, ["update-index", "--add", "--cacheinfo", "160000,#{head},dependency"])
    Fixture.git(repo, ["commit", "-q", "-m", "add gitlink"])
    Fixture.git(repo, ["config", "diff.ignoreSubmodules", "all"])
    assert {:ok, context} = Context.resolve("main HEAD", repo)
    assert context.raw_diff =~ "Subproject commit"
    assert MapSet.member?(context.changed_paths, "dependency")
    assert MapSet.member?(context.valid_lines, {"dependency", 1})
  end

  test "source lines resembling patch headers do not replace the current file", %{repo: repo} do
    File.write!(Path.join(repo, "sample.ex"), "++ b/not-a-file.ex\nnormal source\n")
    Fixture.commit(repo, "diff-like content")
    assert {:ok, context} = Context.resolve("main HEAD", repo)
    assert MapSet.member?(context.valid_lines, {"sample.ex", 1})
    assert MapSet.member?(context.valid_lines, {"sample.ex", 2})
    refute MapSet.member?(context.valid_lines, {"not-a-file.ex", 2})
  end

  test "fix application requires the clean reviewed head in the executing checkout", %{repo: repo} do
    assert {:ok, context} = Context.resolve("main feature", repo)
    assert :ok = Context.verify_fix_checkout(context, repo)
    assert {:error, _} = Context.verify_fix_checkout(context, Path.dirname(repo))
    File.write!(Path.join(repo, "untracked.txt"), "user changes")
    assert {:error, _} = Context.verify_fix_checkout(context, repo)
    Fixture.commit(repo, "new commit after confirmation")
    assert {:error, _} = Context.verify_fix_checkout(context, repo)
  end

  test "UTF-8, quoted and whitespace file names remain valid review anchors", %{repo: repo} do
    names = [
      "català.ex",
      "space name.ex",
      "quote\"name.ex",
      "line\nname.ex",
      "back\\slash.ex",
      "trailing.ex ",
      "trailing-tab.ex\t"
    ]

    Enum.each(names, &File.write!(Path.join(repo, &1), "new source\n"))
    Fixture.commit(repo, "unusual paths")
    assert {:ok, context} = Context.resolve("main HEAD", repo)

    for file <- names do
      assert MapSet.member?(context.changed_paths, file)
      assert MapSet.member?(context.valid_lines, {file, 1})
      assert {:ok, "new source\n"} = Tools.execute("read_file", %{"path" => file}, context)
    end
  end
end
