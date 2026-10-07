defmodule Yoke.PRReview.QueueTest do
  use ExUnit.Case, async: false

  alias Yoke.PRReview.Queue

  @test_dir "test/tmp/queue_test_#{System.unique_integer([:positive])}"

  setup do
    File.mkdir_p!(@test_dir)

    on_exit(fn ->
      File.rm_rf!(@test_dir)
    end)

    :ok
  end

  describe "pick_next/2" do
    test "picks first PR not matching current PR" do
      prs = [
        %{number: 10, title: "PR Ten"},
        %{number: 11, title: "PR Eleven"}
      ]

      assert Queue.pick_next(prs, nil).number == 10
      assert Queue.pick_next(prs, 10).number == 11
      assert Queue.pick_next(prs, 11).number == 10
      assert Queue.pick_next([]) == nil
    end
  end

  describe "skips store" do
    test "loads empty skips map when file does not exist" do
      assert Queue.load_skips(@test_dir) == %{}
    end

    test "skips and unskips properly" do
      skips_path = Path.join(@test_dir, ".yoke/skips.json")
      File.mkdir_p!(Path.dirname(skips_path))
      File.write!(skips_path, ~s({"42": "commit_sha_123"}))

      skips = Queue.load_skips(@test_dir)
      assert Map.get(skips, "42") == "commit_sha_123"

      :ok = Queue.unskip_pr(42, @test_dir)
      updated = Queue.load_skips(@test_dir)
      assert Map.get(updated, "42") == nil
    end
  end
end
