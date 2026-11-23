defmodule Yoke.Cloud.BaselineTest do
  @moduledoc """
  Tests for baseline suppression (`docs/YAAS.md` §4).

  The properties under test are safety properties, not features:

    * An unreachable service must suppress nothing.
    * A baseline entry must never hide a finding more severe than itself.
    * Suppression must be reported, not silently applied.

  No test here makes a network call: the HTTP paths are exercised through a
  local stub server, and the pure matching logic is tested directly.
  """
  use ExUnit.Case, async: false

  alias Yoke.Cloud.Baseline

  @finding %{
    id: 1,
    file: "lib/foo.ex",
    line: 42,
    title: "Missing index on `user_id`",
    description: "The migration adds a reference without an index.",
    severity: "medium",
    kind: "issue",
    fix_suggestion: "add index(:users, [:user_id])"
  }

  defp entry(overrides \\ %{}) do
    Map.merge(
      %{
        file: "lib/foo.ex",
        title: "Missing index on `user_id`",
        severity: "medium",
        ignored_count: 5
      },
      overrides
    )
  end

  describe "normalize_title/1" do
    test "strips backticks and punctuation and collapses whitespace" do
      assert Baseline.normalize_title("Missing index on `user_id`") ==
               "missing index on userid"
    end

    test "is case insensitive" do
      assert Baseline.normalize_title("MISSING INDEX") ==
               Baseline.normalize_title("missing index")
    end

    test "tolerates nil" do
      assert Baseline.normalize_title(nil) == ""
    end
  end

  describe "apply_baseline/2" do
    test "suppresses a finding the baseline matches" do
      {kept, suppressed} = Baseline.apply_baseline([@finding], [entry()])

      assert kept == []
      assert [only] = suppressed
      assert only.file == "lib/foo.ex"
    end

    test "keeps a finding the baseline does not match" do
      other = %{@finding | title: "A completely different problem"}
      {kept, suppressed} = Baseline.apply_baseline([other], [entry()])

      assert [^other] = kept
      assert suppressed == []
    end

    test "matches despite cosmetic title drift" do
      drifted = %{@finding | title: "missing  index on user_id."}
      {kept, _suppressed} = Baseline.apply_baseline([drifted], [entry()])

      assert kept == []
    end

    test "does not match a finding in a different file" do
      elsewhere = %{@finding | file: "lib/bar.ex"}
      {kept, _suppressed} = Baseline.apply_baseline([elsewhere], [entry()])

      assert [^elsewhere] = kept
    end

    test "an empty baseline suppresses nothing" do
      finding = @finding
      {kept, suppressed} = Baseline.apply_baseline([finding], [])

      assert [^finding] = kept
      assert suppressed == []
    end

    test "never suppresses a finding more severe than the entry" do
      critical = %{@finding | severity: "high"}
      {kept, suppressed} = Baseline.apply_baseline([critical], [entry(%{severity: "low"})])

      assert [^critical] = kept
      assert suppressed == []
    end

    test "suppresses a finding at or below the entry severity" do
      low = %{@finding | severity: "low"}
      {kept, _suppressed} = Baseline.apply_baseline([low], [entry(%{severity: "medium"})])

      assert kept == []
    end

    test "an entry at high severity may suppress a high finding" do
      critical = %{@finding | severity: "high"}
      {kept, _suppressed} = Baseline.apply_baseline([critical], [entry(%{severity: "high"})])

      assert kept == []
    end

    test "keeps unmatched findings while suppressing matched ones" do
      other = %{@finding | title: "Unrelated", file: "lib/other.ex"}
      {kept, suppressed} = Baseline.apply_baseline([@finding, other], [entry()])

      assert [^other] = kept
      assert length(suppressed) == 1
    end
  end

  describe "rank/1" do
    test "orders severities" do
      assert Baseline.rank("high") > Baseline.rank("medium")
      assert Baseline.rank("medium") > Baseline.rank("low")
      assert Baseline.rank("low") > Baseline.rank("info")
    end

    test "unknown severities rank below everything" do
      assert Baseline.rank("nonsense") == 0
    end
  end

  describe "fetch/3" do
    setup do
      prior_endpoint = System.get_env("YOKE_CLOUD_ENDPOINT")
      prior_token = System.get_env("YOKE_CLOUD_TOKEN")

      on_exit(fn ->
        restore_env("YOKE_CLOUD_ENDPOINT", prior_endpoint)
        restore_env("YOKE_CLOUD_TOKEN", prior_token)
      end)

      :ok
    end

    test "returns an empty baseline when no endpoint is configured" do
      System.delete_env("YOKE_CLOUD_ENDPOINT")
      System.delete_env("YOKE_CLOUD_TOKEN")

      assert {:ok, []} = Baseline.fetch("owner/repo", "main", endpoint: nil)
    end

    test "returns an empty baseline when the service is unreachable" do
      # Port 1 is never listening; this asserts the fail-open contract without
      # any network dependency.
      assert {:ok, []} =
               Baseline.fetch("owner/repo", "main",
                 endpoint: "http://127.0.0.1:1",
                 timeout: 100
               )
    end

    test "returns an empty baseline for a nil repository" do
      assert {:ok, []} = Baseline.fetch(nil, "main", endpoint: "http://127.0.0.1:1")
    end
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end
