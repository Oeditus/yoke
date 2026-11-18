defmodule Yoke.CLI.FileSystemMacTest do
  use ExUnit.Case, async: false

  import Bitwise

  alias Yoke.CLI.FileSystemMac

  @env_var "FILESYSTEM_FSMAC_EXECUTABLE_FILE"

  setup do
    prev = System.get_env(@env_var)

    on_exit(fn ->
      if is_nil(prev) do
        System.delete_env(@env_var)
      else
        System.put_env(@env_var, prev)
      end
    end)

    :ok
  end

  describe "prepare/0" do
    test "is a no-op in non-escript / non-macOS builds" do
      System.delete_env(@env_var)
      assert :ok == FileSystemMac.prepare()
      assert System.get_env(@env_var) == nil
    end
  end

  describe "extract_and_configure/2" do
    setup do
      tmp_root =
        Path.join(
          System.tmp_dir!(),
          "yoke_fs_mac_test_#{:erlang.unique_integer([:positive])}"
        )

      target_path = Path.join([tmp_root, "file_system", "mac_listener"])
      payload = "fake-mac-listener-binary"
      gz_payload = :zlib.gzip(payload)

      on_exit(fn -> File.rm_rf!(tmp_root) end)

      %{target_path: target_path, payload: payload, gz_payload: gz_payload}
    end

    test "extracts executable binary and sets FILESYSTEM_FSMAC_EXECUTABLE_FILE when unset", %{
      target_path: target_path,
      payload: payload,
      gz_payload: gz_payload
    } do
      System.delete_env(@env_var)

      assert :ok == FileSystemMac.extract_and_configure(target_path, gz_payload)
      assert File.read!(target_path) == payload
      assert (File.stat!(target_path).mode &&& 0o111) != 0
      assert System.get_env(@env_var) == target_path
    end

    test "sets FILESYSTEM_FSMAC_EXECUTABLE_FILE when empty", %{
      target_path: target_path,
      gz_payload: gz_payload
    } do
      System.put_env(@env_var, "")

      assert :ok == FileSystemMac.extract_and_configure(target_path, gz_payload)
      assert System.get_env(@env_var) == target_path
    end

    test "preserves existing FILESYSTEM_FSMAC_EXECUTABLE_FILE override", %{
      target_path: target_path,
      payload: payload,
      gz_payload: gz_payload
    } do
      custom_path = "/custom/path/to/mac_listener"
      System.put_env(@env_var, custom_path)

      assert :ok == FileSystemMac.extract_and_configure(target_path, gz_payload)
      assert File.read!(target_path) == payload
      assert System.get_env(@env_var) == custom_path
    end

    test "is idempotent when target binary already exists", %{
      target_path: target_path,
      payload: payload,
      gz_payload: gz_payload
    } do
      System.delete_env(@env_var)

      assert :ok == FileSystemMac.extract_and_configure(target_path, gz_payload)
      assert :ok == FileSystemMac.extract_and_configure(target_path, gz_payload)
      assert File.read!(target_path) == payload
      assert System.get_env(@env_var) == target_path
    end
  end
end
