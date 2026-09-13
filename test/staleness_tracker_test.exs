defmodule Yoke.StalenessTrackerTest do
  use ExUnit.Case, async: false

  alias Yoke.StalenessTracker

  @tmp_dir Path.join(System.tmp_dir!(), "yoke_staleness_test_#{:rand.uniform(100_000)}")

  setup do
    File.mkdir_p!(@tmp_dir)
    on_exit(fn -> File.rm_rf!(@tmp_dir) end)
    :ok
  end

  describe "compute_fingerprint/1" do
    test "computes deterministic SHA-256 fingerprint for binary string" do
      fp1 = StalenessTracker.compute_fingerprint("hello world")
      fp2 = StalenessTracker.compute_fingerprint("hello world")
      assert is_binary(fp1)
      assert String.length(fp1) == 64
      assert fp1 == fp2
    end
  end

  describe "fingerprint tracking and staleness check" do
    test "tracks fingerprint and detects when resource becomes stale" do
      resource_id = "test_resource_1"
      content_v1 = "initial data"
      content_v2 = "modified data"

      StalenessTracker.record_fingerprint(resource_id, content_v1, cwd: @tmp_dir)
      refute StalenessTracker.stale?(resource_id, content_v1, cwd: @tmp_dir)
      assert StalenessTracker.stale?(resource_id, content_v2, cwd: @tmp_dir)

      # Update to v2
      StalenessTracker.record_fingerprint(resource_id, content_v2, cwd: @tmp_dir)
      refute StalenessTracker.stale?(resource_id, content_v2, cwd: @tmp_dir)
    end
  end
end
