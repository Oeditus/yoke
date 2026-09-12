defmodule Yoke.Workspace.PathTest do
  use ExUnit.Case, async: true

  alias Yoke.Workspace.Path.Boundary
  alias Yoke.Workspace.Path.Lexical
  alias Yoke.Workspace.Path.Resolver

  setup do
    tmp_dir =
      System.tmp_dir!()
      |> Path.join("yoke_path_test_#{:erlang.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)

    on_exit(fn ->
      File.rm_rf!(tmp_dir)
    end)

    {:ok, tmp_dir: tmp_dir}
  end

  test "Boundary.within? checks path component containment", %{tmp_dir: tmp_dir} do
    assert Boundary.within?(tmp_dir, Path.join(tmp_dir, "foo/bar.txt"))
    assert Boundary.within?(tmp_dir, tmp_dir)
    refute Boundary.within?(tmp_dir, tmp_dir <> "-copy")
    refute Boundary.within?(tmp_dir, "/etc/passwd")
  end

  test "Lexical.resolve rejects parent traversals and illegal chars", %{tmp_dir: tmp_dir} do
    assert {:ok, _} = Lexical.resolve(tmp_dir, "lib/app.ex")

    assert {:error, "path contains parent traversal (..)"} =
             Lexical.resolve(tmp_dir, "../secret.txt")

    assert {:error, "path contains null byte"} = Lexical.resolve(tmp_dir, "file\0.txt")

    assert {:error, "path contains backslash separators"} =
             Lexical.resolve(tmp_dir, "win\\path")
  end

  test "Resolver.resolve confines reads and writes inside workspace", %{tmp_dir: tmp_dir} do
    file_path = Path.join(tmp_dir, "test.txt")
    File.write!(file_path, "hello")

    assert {:ok, resolved} = Resolver.resolve(tmp_dir, "test.txt", :read)
    assert resolved == file_path

    # Attempting to resolve file outside workspace
    assert {:error, "path contains parent traversal (..)"} =
             Resolver.resolve(tmp_dir, "../../etc/passwd", :read)
  end
end
