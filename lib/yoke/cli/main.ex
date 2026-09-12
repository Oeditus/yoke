defmodule Yoke.CLI.Main do
  @moduledoc """
  CLI entrypoint module for `yoke` escript executable.
  Supports interactive REPL and command-line execution arguments.
  """
  alias Yoke.Brain.SessionSupervisor
  alias Yoke.CLI.Repl
  alias Yoke.Distribution.NodeManager

  def main(args) do
    # Ensure custom Yoke-style LogFormatter is installed
    Yoke.CLI.LogFormatter.install()

    # Ensure application dependencies are started
    Application.ensure_all_started(:yoke)

    if workspace = System.get_env("YOKE_WORKSPACE") do
      File.cd!(workspace)
    end

    {opts, extra_args, _invalid} =
      OptionParser.parse(args,
        switches: [
          prompt: :string,
          model: :string,
          endpoint: :string,
          conversation: :string,
          resume: :string,
          node: :string,
          connect: :string,
          plugin: :string,
          update: :boolean,
          doctor: :boolean,
          help: :boolean
        ],
        aliases: [
          p: :prompt,
          m: :model,
          e: :endpoint,
          c: :conversation,
          r: :resume,
          u: :update,
          d: :doctor,
          h: :help
        ]
      )

    cond do
      opts[:help] ->
        print_usage()
        halt(0)

      opts[:doctor] ->
        Yoke.CLI.Doctor.print_report()
        halt(0)

      opts[:update] || "update" in extra_args || "self-update" in extra_args ->
        handle_self_update()
        halt(0)

      opts[:node] ->
        NodeManager.start_node(opts[:node])
        if opts[:connect], do: NodeManager.connect(opts[:connect])

        if has_prompt?(opts, extra_args) do
          run_one_shot(opts, extra_args)
        else
          Repl.start(opts)
        end

      has_prompt?(opts, extra_args) ->
        run_one_shot(opts, extra_args)

      true ->
        Repl.start(opts)
    end
  end

  defp has_prompt?(opts, extra_args) do
    prompt_opt = opts[:prompt]
    non_empty_extra = Enum.filter(extra_args, &(String.trim(&1) != ""))

    (is_binary(prompt_opt) and String.trim(prompt_opt) != "") or non_empty_extra != []
  end

  def handle_self_update do
    IO.puts(Yoke.CLI.Formatter.format_info("Checking for Yoke updates…"))

    repo_dir =
      System.get_env("YOKE_REPO_DIR") ||
        Application.get_env(:yoke, :repo_dir) || File.cwd!()

    if File.dir?(Path.join(repo_dir, ".git")) do
      IO.puts(
        Yoke.CLI.Formatter.format_info(
          "Pulling latest git changes and refreshing production release…"
        )
      )

      script = """
      (sleep 0.5 && cd "#{repo_dir}" && git pull --rebase && MIX_ENV=prod mix release --overwrite >/dev/null 2>&1) &
      """

      System.cmd("bash", ["-c", script], cd: repo_dir)

      IO.puts(
        Yoke.CLI.Formatter.format_success(
          "Update initiated! Yoke release will be refreshed in the background."
        )
      )
    else
      IO.puts(Yoke.CLI.Formatter.format_info("Standalone release active."))
    end
  end

  defp run_one_shot(opts, extra_args) do
    prompt = opts[:prompt] || Enum.join(extra_args, " ")
    model = opts[:model] || "deepseek-chat"
    session_id = opts[:conversation] || opts[:resume] || generate_uuid()

    session_opts = [session_id: session_id, model: model]

    session_opts =
      if opts[:endpoint] do
        Keyword.put(session_opts, :endpoint, opts[:endpoint])
      else
        session_opts
      end

    {:ok, session_pid} = SessionSupervisor.start_session(session_opts)

    if opts[:plugin] do
      Yoke.Plugin.Loader.load_file(opts[:plugin])
    end

    result = Repl.handle_input(prompt, session_pid, session_id)

    try do
      Yoke.MCP.ServerManager.stop_ragex()
    catch
      _, _ -> :ok
    end

    Repl.print_resume_banner(session_id)

    case result do
      :continue -> halt(0)
      :exit -> halt(0)
    end
  end

  # Wraps `System.halt/1` so tests can exercise the CLI's exit paths in-process
  # without killing the whole BEAM (and thus the rest of the test suite).
  # Real CLI invocations always halt; tests set
  # `Application.put_env(:yoke, :system_halt_enabled, false)`.
  defp halt(code) do
    if Application.get_env(:yoke, :system_halt_enabled, true) do
      System.halt(code)
    else
      :ok
    end
  end

  def generate_uuid do
    <<a::32, b::16, c::16, d::16, e::48>> = :crypto.strong_rand_bytes(16)

    :io_lib.format("~8.16.0b-~4.16.0b-~4.16.0b-~4.16.0b-~12.16.0b", [a, b, c, d, e])
    |> IO.iodata_to_binary()
  end

  defp print_usage do
    IO.puts("""
    Yoke (Yoke) — CLI Agentic Framework in Elixir

    USAGE:
      yoke                             Launch interactive REPL mode
      yoke -c <conversation_id>        Resume existing conversation
      yoke "Your prompt here"          One-shot mode
      yoke --prompt "Your prompt"      One-shot mode with flags
      yoke --model deepseek-reasoner   Specify model (deepseek-chat or deepseek-reasoner)
      yoke --node brain_1 --connect hands@127.0.0.1   Distributed Brain/Hands mode
      yoke --plugin path/to/plugin.exs Load custom plugin on startup

    OPTIONS:
      -c, --conversation STRING  Resume specific conversation ID
      -p, --prompt STRING        Input prompt to send to agent
      -m, --model STRING         Model selection (deepseek-chat, deepseek-reasoner, deepseek-v4-flash-vision-exp)
          --node STRING          Start local Erlang distributed node name
          --connect STRING       Connect to remote Hands node
          --plugin FILE          Load external Elixir plugin file (.ex or .exs)
      -h, --help                 Display this help message
    """)
  end
end
