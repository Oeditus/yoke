defmodule Yoke.ActionCacheTest do
  use ExUnit.Case, async: true

  @root Path.expand("..", __DIR__)
  @action File.read!(Path.join(@root, "action.yml"))
  @ci File.read!(Path.join(@root, ".github/workflows/ci.yml"))
  @ragex_ci File.read!(Path.join(@root, ".github/workflows/ragex-ci.yml"))

  test "release caches store only the intended executables and never restore other versions" do
    for {name, path} <- [
          {"Restore yoke binary", "~/.local/bin/yoke"},
          {"Restore dllb binary", "~/.local/bin/dllb-server"}
        ] do
      cache = step(@action, name)
      assert cache =~ "uses: actions/cache@v4"
      assert cache =~ "path: #{path}\n"
      assert cache =~ "runner.os"
      assert cache =~ "runner.arch"
      refute cache =~ "restore-keys:"
    end

    yoke = step(@action, "Restore yoke binary")
    assert yoke =~ "inputs.build-from-source != 'true'"
    assert yoke =~ "inputs.yoke-version || format('latest-{0}'"
    assert yoke =~ "inputs.otp-version"
    assert yoke =~ "inputs.elixir-version"
    assert yoke =~ "steps.binary-cache.outputs.yoke-installer"

    dllb = step(@action, "Restore dllb binary")
    assert dllb =~ "inputs.dllb-version != 'skip'"
    assert dllb =~ "inputs.dllb-version || format('latest-{0}'"
    assert dllb =~ "steps.binary-cache.outputs.dllb-installer"
  end

  test "cache hits skip installers but never skip PATH registration or source builds" do
    yoke = step(@action, "Install yoke")
    assert yoke =~ "inputs.build-from-source == 'true' ||"
    assert yoke =~ "steps.yoke-cache.outputs.cache-hit != 'true'"
    assert yoke =~ "MIX_ENV=escript mix escript.build"

    dllb = step(@action, "Install dllb-server")
    assert dllb =~ "inputs.dllb-version != 'skip' &&"
    assert dllb =~ "steps.dllb-cache.outputs.cache-hit != 'true'"

    for source <- [@action, @ci, @ragex_ci] do
      path = step(source, "Add installed binaries to PATH")
      assert path =~ ~s(echo "$HOME/.local/bin" >> "$GITHUB_PATH")
      refute path =~ "if:"
    end
  end

  test "both CI workflows use the same daily dllb cache namespace as the composite action" do
    for source <- [@ci, @ragex_ci] do
      cache = step(source, "Restore dllb binary")
      assert cache =~ "path: ~/.local/bin/dllb-server"
      assert cache =~ "hashFiles('scripts/install-dllb.sh')"
      assert cache =~ "latest-${{ steps.binary-cache.outputs.day }}"
      refute cache =~ "restore-keys:"
      assert step(source, "Install dllb-server") =~ "steps.dllb-cache.outputs.cache-hit != 'true'"
    end

    for source <- [@action, @ci, @ragex_ci] do
      assert step(source, "Restore dllb binary") =~
               "dllb-binary-v1-${{ runner.os }}-${{ runner.arch }}-"
    end
  end

  @tag :tmp_dir
  test "key preparation hashes the action's installers and uses UTC", %{tmp_dir: dir} do
    preparation = step(@action, "Prepare binary cache keys")
    assert preparation =~ "date -u +%F"
    [_, script] = String.split(preparation, "run: |\n", parts: 2)
    output = Path.join(dir, "output")

    assert {_, 0} =
             System.cmd("bash", ["-c", script],
               env: [{"ACTION_PATH", @root}, {"GITHUB_OUTPUT", output}]
             )

    values = File.read!(output)
    assert values =~ "day=#{Date.utc_today()}"

    for {name, file} <- [
          {"yoke", "scripts/install.sh"},
          {"dllb", "scripts/install-dllb.sh"}
        ] do
      digest =
        @root
        |> Path.join(file)
        |> File.read!()
        |> then(&:crypto.hash(:sha256, &1))
        |> Base.encode16(case: :lower)

      assert values =~ "#{name}-installer=#{digest}\n"
    end
  end

  defp step(source, name) do
    source
    |> String.split(~r/(?=^\s*- name: )/m)
    |> Enum.find(fn step ->
      String.starts_with?(String.trim_leading(step), "- name: #{name}\n")
    end)
    |> then(fn
      nil -> flunk("Missing step #{name}")
      step -> step
    end)
  end
end
