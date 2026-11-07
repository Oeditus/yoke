defmodule Yoke.CI.RagTest do
  use ExUnit.Case, async: false
  @moduletag :tmp_dir

  alias Yoke.CI.Rag

  describe "status/1" do
    test "reports graph presence from the .ragex directory", %{tmp_dir: dir} do
      {:ok, status} = Rag.status(dir)

      refute status.graph_present
      assert is_boolean(status.running)
    end

    test "detects an existing graph", %{tmp_dir: dir} do
      File.mkdir_p!(Path.join(dir, ".ragex"))
      {:ok, status} = Rag.status(dir)

      assert status.graph_present
    end
  end

  describe "stop/0" do
    test "is safe when Ragex was never started" do
      assert :ok = Rag.stop()
    end
  end

  describe "index/1" do
    @tag :ragex
    test "returns a map with a status key", %{tmp_dir: dir} do
      {:ok, result} = Rag.index(cwd: dir, timeout: 1_000)

      assert result.status in [:ready, :unavailable]
      assert Map.has_key?(result, :reason)
    end

    test "an unavailable Ragex is reported, not raised", %{tmp_dir: dir} do
      # A 1ms timeout guarantees the await gives up rather than hanging.
      {:ok, result} = Rag.index(cwd: dir, timeout: 1)

      assert result.status in [:ready, :unavailable]

      if result.status == :unavailable do
        assert is_binary(result.reason)
      end
    end
  end
end
