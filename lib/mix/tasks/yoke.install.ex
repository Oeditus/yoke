defmodule Mix.Tasks.Yoke.Install do
  @moduledoc """
  Installs Yoke (`yoke`) globally to `~/.local/bin/yoke`.

  Usage:
      mix yoke.install
  """
  use Mix.Task

  @impl Mix.Task
  def run(_args) do
    Mix.shell().info("Building production OTP release for Yoke…")

    repo_dir = File.cwd!()
    System.cmd("mix", ["deps.get"], cd: repo_dir, stderr_to_stdout: true)

    case System.cmd("mix", ["release", "--overwrite"],
           cd: repo_dir,
           env: [{"MIX_ENV", "prod"}],
           stderr_to_stdout: true
         ) do
      {_out, 0} ->
        Mix.shell().info("Release build successful!")
        install_global_wrapper(repo_dir)

      {err, code} ->
        Mix.shell().error("Release build failed (code #{code}):\n#{err}")
    end
  end

  defp install_global_wrapper(repo_dir) do
    bin_dir = Path.expand("~/.local/bin")
    File.mkdir_p!(bin_dir)

    target_wrapper = Path.join(bin_dir, "yoke")
    yoke_launcher = Path.join(repo_dir, "yoke")

    script_content = """
    #!/usr/bin/env bash
    set -e
    export YOKE_WORKSPACE="$PWD"
    export YOKE_REPO_DIR="#{repo_dir}"
    # Ragex's per-project store backend spawns `dllb-server` as an OS process.
    # Resolve it here so a globally installed `yoke` finds a binary that is not
    # on PATH -- otherwise every run logs `:dllb_binary_not_found` and falls
    # back to the slower ETS backend. Mirrors the search in the repo launcher.
    export DLLB_DIR="${DLLB_DIR:-$(cd "#{repo_dir}/../dllb" 2>/dev/null && pwd || echo "#{repo_dir}/../dllb")}"
    if [ -z "${DLLB_SERVER_BIN:-}" ] || [ ! -f "${DLLB_SERVER_BIN}" ]; then
      for candidate in \\
        "$DLLB_DIR/target/release/dllb-server" \\
        "$DLLB_DIR/target/debug/dllb-server" \\
        "$HOME/.local/bin/dllb-server" \\
        "$HOME/.cargo/bin/dllb-server" \\
        "/usr/local/bin/dllb-server"; do
        if [ -f "$candidate" ]; then
          export DLLB_SERVER_BIN="$candidate"
          break
        fi
      done
    fi
    if [ -z "${DLLB_SERVER_BIN:-}" ] && command -v dllb-server >/dev/null 2>&1; then
      export DLLB_SERVER_BIN="$(command -v dllb-server)"
    fi
    cd "$PWD"
    exec "#{yoke_launcher}" --prod "$@"
    """

    File.write!(target_wrapper, script_content)
    File.chmod!(target_wrapper, 0o755)

    Mix.shell().info("""
    󰄬 Yoke installed globally to: #{target_wrapper}

    Ensure '#{bin_dir}' is in your $PATH:
      export PATH="$HOME/.local/bin:$PATH"

    You can now run 'yoke' from ANY project directory!
    """)
  end
end
