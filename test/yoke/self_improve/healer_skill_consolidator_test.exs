defmodule Yoke.SelfImprove.HealerSkillConsolidatorTest do
  use ExUnit.Case, async: true

  alias Yoke.SelfImprove.{Consolidator, Guardrails, Healer, SkillSynthesizer}
  alias Yoke.Skill.Manager

  setup do
    tmp = Path.join(System.tmp_dir!(), "yoke_hsc_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)
    {:ok, cwd: tmp}
  end

  test "healer proposes scoped rules from critic findings and caches reflexes", %{cwd: cwd} do
    items =
      Healer.heal_from_critic(
        %{findings: ["Used plain bash 2x where dedicated/Ragex tools exist"]},
        cwd
      )

    assert length(items) == 1

    {:ok, _} =
      Healer.record_reflex("enoent: test/foo_test.exs", "Tests live under test/unit/", cwd)

    assert Healer.lookup_reflex("File.read failed (ENOENT: test/foo_test.exs)", cwd) ==
             "Tests live under test/unit/"
  end

  test "skill synthesizer creates a discoverable SKILL.md after 3 repeated sequences", %{cwd: cwd} do
    seq = ["run_linter", "read_file", "replace_file"]

    {:ok, []} = SkillSynthesizer.observe_sequence(seq, cwd)
    {:ok, []} = SkillSynthesizer.observe_sequence(seq, cwd)
    {:ok, [skill_path]} = SkillSynthesizer.observe_sequence(seq, cwd)

    assert File.exists?(skill_path)
    skills = Manager.discover_skills(cwd: cwd, cache: false)
    assert Enum.any?(skills, &String.starts_with?(&1.name, "auto_"))
  end

  test "consolidator graduates staged rules into Yoke.Rules and writes briefing.md", %{cwd: cwd} do
    {:ok, _} = Guardrails.propose(:rule, "all: Always format Elixir files", cwd: cwd)
    {:ok, _} = Guardrails.propose(:rule, "all: Always format Elixir files", cwd: cwd)

    {:ok, report} = Consolidator.consolidate(cwd)
    assert report.promoted_count == 1

    assert Enum.any?(
             Yoke.Rules.load_rules(cwd),
             &String.contains?(&1["text"], "Always format Elixir files")
           )

    briefing = Consolidator.read_briefing(cwd)
    assert is_binary(briefing)
    assert briefing =~ "Yoke Self-Improvement Briefing"
  end
end
