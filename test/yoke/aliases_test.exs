defmodule Yoke.AliasesTest do
  use ExUnit.Case, async: false

  alias Yoke.Aliases

  setup do
    tmp_dir =
      Path.join(System.tmp_dir!(), "yoke_aliases_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(tmp_dir, ".yoke"))
    on_exit(fn -> File.rm_rf(tmp_dir) end)

    %{tmp_dir: tmp_dir}
  end

  test "initializes default aliases if aliases.json is missing", %{tmp_dir: tmp_dir} do
    aliases = Aliases.load_aliases(tmp_dir)
    assert Map.has_key?(aliases, "finish")
    assert Map.has_key?(aliases, "pr")
    assert Map.has_key?(aliases, "commit-structured")
    assert Map.has_key?(aliases, "cpr")

    finish = aliases["finish"]
    assert finish["name"] == "finish"
    assert is_list(finish["commands"])
    assert length(finish["commands"]) == 2

    # Verify all 5 structured sections are mentioned
    [stage_cmd, commit_prompt] = finish["commands"]
    assert stage_cmd =~ "{{#if_args}}!git add {{args}}{{/if_args}}"
    assert commit_prompt =~ "The PR reason"
    assert commit_prompt =~ "Implementation"
    assert commit_prompt =~ "How to verify"
    assert commit_prompt =~ "Risk & rollout"
    assert commit_prompt =~ "Reviewer guidance"
  end

  test "loads aliases from local .yoke/aliases.json", %{tmp_dir: tmp_dir} do
    custom = %{
      "my-flow" => %{
        "name" => "my-flow",
        "description" => "Custom flow",
        "commands" => ["!echo 'hello'", "!echo 'world'"]
      }
    }

    aliases_file = Path.join([tmp_dir, ".yoke", "aliases.json"])
    File.write!(aliases_file, Jason.encode!(custom))

    aliases = Aliases.load_aliases(tmp_dir)
    assert Map.has_key?(aliases, "my-flow")
    assert aliases["my-flow"]["commands"] == ["!echo 'hello'", "!echo 'world'"]
  end

  test "loads aliases from local .yoke/config.json under aliases key", %{tmp_dir: tmp_dir} do
    cfg = %{
      "model" => "deepseek-flash",
      "aliases" => %{
        "config-alias" => "!mix test"
      }
    }

    cfg_file = Path.join([tmp_dir, ".yoke", "config.json"])
    File.write!(cfg_file, Jason.encode!(cfg))

    aliases = Aliases.load_aliases(tmp_dir)
    assert Map.has_key?(aliases, "config-alias")
    assert aliases["config-alias"]["commands"] == ["!mix test"]
  end

  test "adds, retrieves, and deletes aliases", %{tmp_dir: tmp_dir} do
    new_alias = %{
      "name" => "deploy-check",
      "description" => "Run pre-deploy checks",
      "commands" => ["!mix compile --warnings-as-errors", "!mix test"]
    }

    assert {:ok, _path} = Aliases.save_alias(new_alias, tmp_dir)

    assert {:ok, fetched} = Aliases.get_alias("deploy-check", tmp_dir)
    assert fetched["name"] == "deploy-check"
    assert fetched["commands"] == ["!mix compile --warnings-as-errors", "!mix test"]

    assert "deploy-check" in Aliases.list_alias_names(tmp_dir)

    assert {:ok, "deploy-check"} = Aliases.delete_alias("deploy-check", tmp_dir)
    refute "deploy-check" in Aliases.list_alias_names(tmp_dir)
  end

  describe "interpolate/2" do
    test "replaces {{args}}, $@, and $*" do
      template = "!git add {{args}}"

      assert Aliases.interpolate(template, "lib/foo.ex lib/bar.ex") ==
               "!git add lib/foo.ex lib/bar.ex"

      template2 = "!echo $@"
      assert Aliases.interpolate(template2, "hello world") == "!echo hello world"
    end

    test "replaces positional parameters $1, $2, {{arg1}}" do
      template = "!git diff $1...$2"
      assert Aliases.interpolate(template, "main feature") == "!git diff main...feature"

      template2 = "!echo {{arg1}} and {{arg2}}"
      assert Aliases.interpolate(template2, "first second") == "!echo first and second"
    end

    test "handles {{#if_args}} and {{#unless_args}} conditionals" do
      template = "{{#if_args}}!git add {{args}}{{/if_args}}"

      # When args are given
      assert Aliases.interpolate(template, "file1.ex") == "!git add file1.ex"

      # When no args are given
      assert Aliases.interpolate(template, "") == ""
      assert Aliases.interpolate(template, "   ") == ""

      template_unless = "{{#unless_args}}No files specified{{/unless_args}}"
      assert Aliases.interpolate(template_unless, "") == "No files specified"
      assert Aliases.interpolate(template_unless, "file1.ex") == ""
    end

    test "handles --commit-only, -c flags and conditionals" do
      template =
        "Commit changes. {{#if_commit_only}}Commit only; no PR.{{/if_commit_only}}{{#unless_commit_only}}Create PR.{{/unless_commit_only}}"

      # Default: creates PR
      assert Aliases.interpolate(template, "") == "Commit changes. Create PR."

      # With --commit-only flag
      assert Aliases.interpolate(template, "--commit-only") ==
               "Commit changes. Commit only; no PR."

      # With -c flag
      assert Aliases.interpolate(template, "-c") == "Commit changes. Commit only; no PR."

      # With files and --commit-only flag
      assert Aliases.interpolate(
               "{{#if_args}}!git add {{args}}{{/if_args}}",
               "lib/app.ex --commit-only"
             ) == "!git add lib/app.ex"
    end

    test "appends arguments when template has no placeholders" do
      template = "!git status"
      assert Aliases.interpolate(template, "--short") == "!git status --short"

      prompt_template = "Please check the code formatting"

      assert Aliases.interpolate(prompt_template, "lib/yoke/cli") ==
               "Please check the code formatting\n\nSpecified target(s): lib/yoke/cli"
    end
  end

  describe "expand_alias/2" do
    test "expands finish alias with no args (using manual git add / staged files)" do
      alias_def = Aliases.default_aliases()["finish"]

      {:ok, commands} = Aliases.expand_alias(alias_def, "")
      # The staging command is skipped because no files were specified
      assert length(commands) == 1
      [prompt] = commands

      refute prompt =~ "!git add"
      assert prompt =~ "The PR reason"
      assert prompt =~ "Implementation"
      assert prompt =~ "How to verify"
      assert prompt =~ "Risk & rollout"
      assert prompt =~ "Reviewer guidance"
      assert prompt =~ "gh pr create"
    end

    test "expands finish alias with explicit files" do
      alias_def = Aliases.default_aliases()["finish"]

      {:ok, commands} =
        Aliases.expand_alias(alias_def, "lib/yoke/aliases.ex lib/yoke/cli/repl.ex")

      # Staging command is included, followed by commit prompt
      assert length(commands) == 2
      [stage_cmd, prompt] = commands

      assert stage_cmd == "!git add lib/yoke/aliases.ex lib/yoke/cli/repl.ex"
      assert prompt =~ "The PR reason"
      assert prompt =~ "gh pr create"
    end

    test "expands finish alias with --commit-only" do
      alias_def = Aliases.default_aliases()["finish"]

      {:ok, commands} = Aliases.expand_alias(alias_def, "--commit-only")
      assert length(commands) == 1
      [prompt] = commands

      assert prompt =~ "Commit the changes with this message only; do not open a pull request."
      refute prompt =~ "gh pr create"
    end

    test "expands finish alias with files and --commit-only" do
      alias_def = Aliases.default_aliases()["finish"]

      {:ok, commands} =
        Aliases.expand_alias(alias_def, "lib/yoke/aliases.ex --commit-only")

      assert length(commands) == 2
      [stage_cmd, prompt] = commands

      assert stage_cmd == "!git add lib/yoke/aliases.ex"
      assert prompt =~ "Commit the changes with this message only; do not open a pull request."
      refute prompt =~ "gh pr create"
    end

    test "expands dedicated commit-structured alias" do
      alias_def = Aliases.default_aliases()["commit-structured"]

      {:ok, commands} = Aliases.expand_alias(alias_def, "lib/yoke.ex")
      assert length(commands) == 2
      [stage_cmd, prompt] = commands

      assert stage_cmd == "!git add lib/yoke.ex"
      assert prompt =~ "The PR reason"
      refute prompt =~ "gh pr create"
    end
  end
end
