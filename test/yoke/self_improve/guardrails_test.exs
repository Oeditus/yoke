defmodule Yoke.SelfImprove.GuardrailsTest do
  use ExUnit.Case, async: true

  alias Yoke.SelfImprove.Guardrails

  setup do
    tmp = Path.join(System.tmp_dir!(), "yoke_guardrails_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)
    {:ok, cwd: tmp}
  end

  test "propose deduplicates by key and increments observations", %{cwd: cwd} do
    {:ok, item1} = Guardrails.propose(:rule, "Always run mix format", cwd: cwd)
    assert item1["observations"] == 1
    assert item1["status"] == "proposed"

    {:ok, item2} = Guardrails.propose(:rule, "Always run mix format", cwd: cwd)
    assert item2["id"] == item1["id"]
    assert item2["observations"] == 2
  end

  test "auto_graduate promotes items with >= 2 observations and zero undos", %{cwd: cwd} do
    {:ok, item} = Guardrails.propose(:lesson, "Check old_content before edit", cwd: cwd)
    {:ok, _} = Guardrails.propose(:lesson, "Check old_content before edit", cwd: cwd)
    {:ok, single} = Guardrails.propose(:lesson, "One-off quirk", cwd: cwd, ttl_sessions: 1)

    {:ok, %{promoted: promoted, expired: expired}} = Guardrails.auto_graduate(cwd: cwd)

    assert Enum.any?(promoted, &(&1["id"] == item["id"] and &1["status"] == "active"))
    assert Enum.any?(expired, &(&1["id"] == single["id"] and &1["status"] == "expired"))
  end

  test "record_undo blocks auto-graduation and expires on >= 2 undos", %{cwd: cwd} do
    {:ok, item} = Guardrails.propose(:rule, "Bad rule", cwd: cwd)
    {:ok, _} = Guardrails.propose(:rule, "Bad rule", cwd: cwd)
    {:ok, _} = Guardrails.record_undo(item["id"], cwd)

    {:ok, %{promoted: promoted}} = Guardrails.auto_graduate(cwd: cwd)
    assert promoted == []

    {:ok, _} = Guardrails.record_undo(item["id"], cwd)
    {:ok, %{expired: expired}} = Guardrails.auto_graduate(cwd: cwd)
    assert Enum.any?(expired, &(&1["id"] == item["id"]))
  end

  test "fit_to_budget ranks by score and respects max_tokens" do
    entries = [
      %{text: String.duplicate("a", 40), score: 0.2},
      %{text: String.duplicate("b", 40), score: 0.9},
      %{text: String.duplicate("c", 40), score: 0.6}
    ]

    # 25 tokens = 100 chars -> fits 2 entries (40 + 2 + 40 = 82 chars)
    kept = Guardrails.fit_to_budget(entries, max_tokens: 25)
    assert length(kept) == 2
    assert Enum.map(kept, & &1.score) == [0.9, 0.6]
  end

  test "can_auto_switch? enforces hysteresis cooldown" do
    assert Guardrails.can_auto_switch?(1, nil)
    refute Guardrails.can_auto_switch?(4, 3, cooldown_turns: 2)
    assert Guardrails.can_auto_switch?(5, 3, cooldown_turns: 2)
  end
end
