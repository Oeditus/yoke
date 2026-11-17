defmodule Yoke.AutoUpdateTest do
  use ExUnit.Case, async: false

  alias Yoke.AutoUpdate

  @temp_dir Path.expand("test/tmp/auto_update_test_#{System.unique_integer([:positive])}")

  @env_vars ~w(
    YOKE_NO_AUTO_UPDATE
    YOKE_DISABLE_AUTO_UPDATE
    YOKE_UPDATE_CHECK_INTERVAL
    YOKE_FORCE_RELEASE_INSTALL
    CI
    GITHUB_ACTIONS
    CONTINUOUS_INTEGRATION
  )

  setup do
    File.mkdir_p!(@temp_dir)
    state_file = Path.join(@temp_dir, "update_check.json")

    # Clear any env overrides
    prior = Map.new(@env_vars, fn var -> {var, System.get_env(var)} end)
    Enum.each(@env_vars, &System.delete_env/1)

    on_exit(fn ->
      File.rm_rf!(@temp_dir)

      Enum.each(prior, fn
        {var, nil} -> System.delete_env(var)
        {var, value} -> System.put_env(var, value)
      end)
    end)

    {:ok, state_file: state_file, temp_dir: @temp_dir}
  end

  describe "compare_versions/2" do
    test "correctly detects newer version" do
      assert AutoUpdate.compare_versions("v0.23.0", "0.22.6") == :newer
      assert AutoUpdate.compare_versions("0.23.0", "0.22.6") == :newer
      assert AutoUpdate.compare_versions("v1.0.0", "v0.22.6") == :newer
      assert AutoUpdate.compare_versions("0.22.7", "0.22.6") == :newer
    end

    test "correctly detects up-to-date version" do
      assert AutoUpdate.compare_versions("v0.22.6", "0.22.6") == :up_to_date
      assert AutoUpdate.compare_versions("0.22.6", "0.22.6") == :up_to_date
      assert AutoUpdate.compare_versions("v0.22.6", "v0.22.6") == :up_to_date
    end

    test "correctly detects older version" do
      assert AutoUpdate.compare_versions("v0.22.5", "0.22.6") == :older
      assert AutoUpdate.compare_versions("0.21.0", "0.22.6") == :older
    end

    test "returns :error for malformed versions" do
      assert AutoUpdate.compare_versions("not_a_version", "0.22.6") == :error
      assert AutoUpdate.compare_versions("v1.0.0", "invalid") == :error
    end
  end

  describe "state persistence" do
    test "writes and reads state file correctly", %{state_file: state_file} do
      assert AutoUpdate.read_state(state_file: state_file) == %{}

      AutoUpdate.write_state(%{"last_check_at" => 1_700_000_000, "seen" => "0.22.6"},
        state_file: state_file
      )

      state = AutoUpdate.read_state(state_file: state_file)

      assert state["last_check_at"] == 1_700_000_000
      assert state["seen"] == "0.22.6"
    end

    test "record_check_time/1 updates last_check_at", %{state_file: state_file} do
      now = System.system_time(:second)
      AutoUpdate.record_check_time(state_file: state_file)

      state = AutoUpdate.read_state(state_file: state_file)
      assert is_integer(state["last_check_at"])
      assert state["last_check_at"] >= now
    end
  end

  describe "should_check?/1" do
    test "returns true when force: true regardless of interval, release status or env", %{
      state_file: state_file
    } do
      System.put_env("YOKE_NO_AUTO_UPDATE", "1")
      assert AutoUpdate.should_check?(force: true, state_file: state_file)
    end

    test "returns false when running from source, even if interactive", %{state_file: state_file} do
      # In the source repository checkout, auto-update is OFF
      refute AutoUpdate.should_check?(interactive: true, state_file: state_file)

      refute AutoUpdate.should_check?(
               interactive: true,
               from_source: true,
               is_release: true,
               state_file: state_file
             )
    end

    test "returns true when running as published release (not from source)", %{
      state_file: state_file
    } do
      assert AutoUpdate.should_check?(
               published_release: true,
               interactive: true,
               state_file: state_file
             )
    end

    test "returns false when disabled via environment variable", %{state_file: state_file} do
      System.put_env("YOKE_NO_AUTO_UPDATE", "1")

      refute AutoUpdate.should_check?(
               published_release: true,
               interactive: true,
               state_file: state_file
             )

      System.delete_env("YOKE_NO_AUTO_UPDATE")
      System.put_env("YOKE_DISABLE_AUTO_UPDATE", "true")

      refute AutoUpdate.should_check?(
               published_release: true,
               interactive: true,
               state_file: state_file
             )
    end

    test "returns false when running in CI environment", %{state_file: state_file} do
      System.put_env("CI", "true")

      refute AutoUpdate.should_check?(
               published_release: true,
               interactive: true,
               state_file: state_file
             )

      System.delete_env("CI")
      System.put_env("GITHUB_ACTIONS", "true")

      refute AutoUpdate.should_check?(
               published_release: true,
               interactive: true,
               state_file: state_file
             )

      System.delete_env("GITHUB_ACTIONS")
      System.put_env("CONTINUOUS_INTEGRATION", "1")

      refute AutoUpdate.should_check?(
               published_release: true,
               interactive: true,
               state_file: state_file
             )

      System.delete_env("CONTINUOUS_INTEGRATION")

      # Also respects explicit ci option
      refute AutoUpdate.should_check?(
               ci: true,
               published_release: true,
               interactive: true,
               state_file: state_file
             )
    end

    test "returns false when non-interactive", %{state_file: state_file} do
      refute AutoUpdate.should_check?(
               published_release: true,
               interactive: false,
               state_file: state_file
             )
    end

    test "throttles checks when last check is within interval", %{state_file: state_file} do
      now = System.system_time(:second)
      # Check happened 10 minutes ago
      AutoUpdate.write_state(%{"last_check_at" => now - 600}, state_file: state_file)

      # Default 86400 interval
      refute AutoUpdate.should_check?(
               published_release: true,
               interactive: true,
               state_file: state_file,
               interval: 86_400
             )
    end

    test "allows check when last check was long ago", %{state_file: state_file} do
      now = System.system_time(:second)
      # Check happened 2 days ago
      AutoUpdate.write_state(%{"last_check_at" => now - 172_800}, state_file: state_file)

      assert AutoUpdate.should_check?(
               published_release: true,
               interactive: true,
               state_file: state_file,
               interval: 86_400
             )
    end

    test "allows check when no prior check exists on published release", %{state_file: state_file} do
      assert AutoUpdate.should_check?(
               published_release: true,
               interactive: true,
               state_file: state_file
             )
    end
  end

  describe "published_release?/1 and running_from_source?/1" do
    test "detects running from source in the repository" do
      assert AutoUpdate.running_from_source?()
      refute AutoUpdate.published_release?()
    end

    test "detects source repo from nested directories" do
      lib_dir = Path.expand("lib/yoke")
      assert AutoUpdate.find_yoke_source_repo(lib_dir) == File.cwd!()
      assert AutoUpdate.find_yoke_source_repo(Path.expand("test")) == File.cwd!()

      outside_dir =
        Path.join(System.tmp_dir!(), "non_yoke_dir_#{System.unique_integer([:positive])}")

      assert AutoUpdate.find_yoke_source_repo(outside_dir) == nil
    end

    test "published_release? returns true only when is_release is true and from_source is false" do
      assert AutoUpdate.published_release?(is_release: true, from_source: false)
      refute AutoUpdate.published_release?(is_release: true, from_source: true)
      refute AutoUpdate.published_release?(is_release: false, from_source: false)
    end
  end

  describe "verify_checksum/2" do
    test "verifies correct sha256 checksum" do
      content = "binary payload for yoke"
      sha = :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
      sha_text = "#{sha}  yoke\n"

      assert AutoUpdate.verify_checksum(content, sha_text) == :ok
    end

    test "fails on checksum mismatch" do
      content = "binary payload for yoke"
      sha_text = "0000000000000000000000000000000000000000000000000000000000000000  yoke\n"

      assert {:error, msg} = AutoUpdate.verify_checksum(content, sha_text)
      assert msg =~ "Checksum verification failed"
    end
  end

  describe "install_binary/2" do
    test "atomically writes binary and marks executable", %{temp_dir: temp_dir} do
      target = Path.join(temp_dir, "bin/yoke")
      content = "#!/bin/sh\necho updated\n"

      assert {:ok, ^target} = AutoUpdate.install_binary(content, target)
      assert File.exists?(target)
      assert File.read!(target) == content

      stat = File.stat!(target)
      # Check executable bit is set (0o755)
      assert Bitwise.band(stat.mode, 0o111) != 0
    end
  end

  describe "check_for_updates/1 with mock plug" do
    test "returns :newer_version when release tag is higher" do
      release_payload = %{
        "tag_name" => "v0.99.0",
        "assets" => [
          %{"name" => "yoke", "browser_download_url" => "https://example.com/yoke"},
          %{"name" => "yoke.sha256", "browser_download_url" => "https://example.com/yoke.sha256"}
        ]
      }

      plug = fn conn ->
        Plug.Conn.send_resp(conn, 200, Yoke.Json.encode!(release_payload))
      end

      assert {:newer_version, "0.99.0", data} =
               AutoUpdate.check_for_updates(
                 plug: plug,
                 current_version: "0.22.6",
                 state_file: Path.join(@temp_dir, "state.json")
               )

      assert data["tag_name"] == "v0.99.0"
    end

    test "returns :up_to_date when release tag is equal" do
      release_payload = %{
        "tag_name" => "v0.22.6",
        "assets" => []
      }

      plug = fn conn ->
        Plug.Conn.send_resp(conn, 200, Yoke.Json.encode!(release_payload))
      end

      assert {:up_to_date, "0.22.6"} =
               AutoUpdate.check_for_updates(
                 plug: plug,
                 current_version: "0.22.6",
                 state_file: Path.join(@temp_dir, "state.json")
               )
    end

    test "returns :error when HTTP request fails" do
      plug = fn conn ->
        Plug.Conn.send_resp(conn, 500, "Internal Server Error")
      end

      assert {:error, {:http_error, 500}} =
               AutoUpdate.check_for_updates(
                 plug: plug,
                 state_file: Path.join(@temp_dir, "state.json")
               )
    end
  end

  describe "maybe_check_and_prompt/1 flow" do
    test "downloads and installs when user accepts prompt", %{temp_dir: temp_dir} do
      binary_content = "#!/bin/sh\necho yoke-v0.23.0\n"
      sha = :crypto.hash(:sha256, binary_content) |> Base.encode16(case: :lower)
      sha_text = "#{sha}  yoke\n"

      target_file = Path.join(temp_dir, "installed/yoke")
      state_file = Path.join(temp_dir, "state.json")

      plug = fn conn ->
        cond do
          String.contains?(conn.request_path, "releases/latest") ->
            payload = %{
              "tag_name" => "v0.23.0",
              "assets" => [
                %{
                  "name" => "yoke",
                  "browser_download_url" => "https://example.com/download/yoke"
                },
                %{
                  "name" => "yoke.sha256",
                  "browser_download_url" => "https://example.com/download/yoke.sha256"
                }
              ]
            }

            Plug.Conn.send_resp(conn, 200, Yoke.Json.encode!(payload))

          String.contains?(conn.request_path, "download/yoke.sha256") ->
            Plug.Conn.send_resp(conn, 200, sha_text)

          String.contains?(conn.request_path, "download/yoke") ->
            Plug.Conn.send_resp(conn, 200, binary_content)
        end
      end

      # Prompt accepts update
      prompt_fn = fn _latest, _curr -> true end

      result =
        AutoUpdate.maybe_check_and_prompt(
          plug: plug,
          force: true,
          current_version: "0.22.6",
          target_path: target_file,
          state_file: state_file,
          prompt_fn: prompt_fn,
          force_binary: true
        )

      assert {:ok, :installed, "0.23.0"} = result
      assert File.exists?(target_file)
      assert File.read!(target_file) == binary_content
    end

    test "skips install when user declines prompt", %{temp_dir: temp_dir} do
      target_file = Path.join(temp_dir, "installed/yoke")
      state_file = Path.join(temp_dir, "state.json")

      plug = fn conn ->
        payload = %{
          "tag_name" => "v0.23.0",
          "assets" => [
            %{"name" => "yoke", "browser_download_url" => "https://example.com/download/yoke"}
          ]
        }

        Plug.Conn.send_resp(conn, 200, Yoke.Json.encode!(payload))
      end

      # Prompt declines update
      prompt_fn = fn _latest, _curr -> false end

      result =
        AutoUpdate.maybe_check_and_prompt(
          plug: plug,
          force: true,
          current_version: "0.22.6",
          target_path: target_file,
          state_file: state_file,
          prompt_fn: prompt_fn
        )

      assert {:ok, :declined} = result
      refute File.exists?(target_file)
    end

    test "returns :skipped when should_check? is false", %{state_file: state_file} do
      result =
        AutoUpdate.maybe_check_and_prompt(
          interactive: false,
          state_file: state_file
        )

      assert {:ok, :skipped} = result
    end
  end

  describe "yoke_source_repo?/1" do
    test "returns true for the project repository" do
      assert AutoUpdate.yoke_source_repo?(File.cwd!())
    end

    test "returns false for temporary non-yoke directories", %{temp_dir: temp_dir} do
      refute AutoUpdate.yoke_source_repo?(temp_dir)
      refute AutoUpdate.yoke_source_repo?(nil)
    end
  end

  describe "manual_update/1 and cli_update/1" do
    test "returns 0 when already up to date" do
      plug = fn conn ->
        payload = %{"tag_name" => "v0.22.6", "assets" => []}
        Plug.Conn.send_resp(conn, 200, Yoke.Json.encode!(payload))
      end

      assert AutoUpdate.manual_update(
               plug: plug,
               current_version: "0.22.6",
               state_file: Path.join(@temp_dir, "manual_state.json")
             ) == 0
    end

    test "returns 0 and installs when newer version is approved", %{temp_dir: temp_dir} do
      binary_content = "#!/bin/sh\necho updated\n"
      target = Path.join(temp_dir, "bin/yoke")

      plug = fn conn ->
        cond do
          String.contains?(conn.request_path, "releases/latest") ->
            payload = %{
              "tag_name" => "v0.23.0",
              "assets" => [
                %{"name" => "yoke", "browser_download_url" => "https://example.com/dl/yoke"}
              ]
            }

            Plug.Conn.send_resp(conn, 200, Yoke.Json.encode!(payload))

          String.contains?(conn.request_path, "dl/yoke") ->
            Plug.Conn.send_resp(conn, 200, binary_content)
        end
      end

      assert AutoUpdate.manual_update(
               plug: plug,
               current_version: "0.22.6",
               target_path: target,
               prompt_fn: fn _new, _curr -> true end,
               force_binary: true,
               state_file: Path.join(temp_dir, "manual_state2.json")
             ) == 0

      assert File.exists?(target)
    end

    test "returns 0 when user cancels" do
      plug = fn conn ->
        payload = %{
          "tag_name" => "v0.23.0",
          "assets" => [
            %{"name" => "yoke", "browser_download_url" => "https://example.com/dl/yoke"}
          ]
        }

        Plug.Conn.send_resp(conn, 200, Yoke.Json.encode!(payload))
      end

      assert AutoUpdate.manual_update(
               plug: plug,
               current_version: "0.22.6",
               prompt_fn: fn _new, _curr -> false end,
               state_file: Path.join(@temp_dir, "manual_state3.json")
             ) == 0
    end

    test "returns 1 when release check fails with error" do
      plug = fn conn ->
        Plug.Conn.send_resp(conn, 500, "Error")
      end

      assert AutoUpdate.manual_update(
               plug: plug,
               state_file: Path.join(@temp_dir, "manual_state4.json")
             ) == 1
    end
  end

  describe "resolve_target_path/1" do
    test "prefers explicit target_path option" do
      assert AutoUpdate.resolve_target_path(target_path: "/custom/path/yoke") ==
               "/custom/path/yoke"
    end

    test "uses YOKE_INSTALL_PATH env var" do
      System.put_env("YOKE_INSTALL_PATH", "/env/path/yoke")
      on_exit(fn -> System.delete_env("YOKE_INSTALL_PATH") end)

      assert AutoUpdate.resolve_target_path() == "/env/path/yoke"
    end
  end

  describe "parse_interval/1" do
    test "parses integers and numeric strings" do
      assert AutoUpdate.parse_interval(3600) == 3600
      assert AutoUpdate.parse_interval("7200") == 7200
      assert AutoUpdate.parse_interval("invalid") == nil
      assert AutoUpdate.parse_interval(-10) == nil
    end
  end

  describe "install_from_release/2 error handling" do
    test "returns error when 'yoke' asset is not found in release" do
      release_data = %{"tag_name" => "v1.0.0", "assets" => [%{"name" => "other"}]}
      assert {:error, msg} = AutoUpdate.install_from_release(release_data)
      assert msg =~ "No 'yoke' binary asset found"
    end
  end
end
