defmodule Yoke.CLI.Main do
  @moduledoc """
  CLI entrypoint module for `yoke` escript executable.
  Supports interactive REPL and command-line execution arguments.

  ## Subcommand dispatch

  `yoke <subcommand> ...` is routed through `@subcommands`. The table is
  deliberately built out in full even where only some entries are wired yet
  (`docs/CI_PLAN.md` Phase 1.1), so later capabilities are *additive* rather
  than a refactor. An entry that is not yet implemented prints a clear
  "not implemented" message and exits non-zero, rather than silently falling
  through to the REPL.

  Anything that is not a known subcommand keeps the historical behaviour:
  one-shot mode when a prompt is present, otherwise the interactive REPL.
  """
  alias Yoke.Brain.SessionSupervisor
  alias Yoke.CLI.Repl
  alias Yoke.Distribution.NodeManager

  # The full dispatch table. Every entry is wired; the `:planned` status is
  # retained in the vocabulary so a future command can be advertised before it
  # is implemented (see `dispatch_subcommand/2`).
  @subcommands %{
    "review" => %{module: Yoke.CLI.CI, fun: :review, status: :implemented},
    "lint" => %{module: Yoke.CLI.CI, fun: :lint, status: :implemented},
    "describe" => %{module: Yoke.CLI.CI, fun: :describe, status: :implemented},
    "run" => %{module: Yoke.CLI.CI, fun: :run_workflow, status: :implemented},
    "audit" => %{module: Yoke.CLI.CI, fun: :audit, status: :implemented},
    "rag" => %{module: Yoke.CLI.CI, fun: :rag, status: :implemented}
  }

  @doc "Returns the subcommand dispatch table."
  @spec subcommands() :: %{String.t() => map()}
  def subcommands, do: @subcommands

  def main(args) do
    # Probe terminal capability FIRST, before anything else can write output.
    # `Application.ensure_all_started/1` below logs startup lines through
    # `Yoke.CLI.LogFormatter`, so priming after it would let ANSI escapes
    # reach a CI log for the entire boot sequence. In CI (`</dev/null`,
    # piped stdout) this pins the presentation seam to `:plain` up front.
    Yoke.CLI.Output.prime()

    # Ensure custom Yoke-style LogFormatter is installed
    Yoke.CLI.LogFormatter.install()

    configure_ragex_ai()
    configure_exla()

    # Ensure application dependencies are started
    Application.ensure_all_started(:yoke)

    if workspace = System.get_env("YOKE_WORKSPACE") do
      File.cd!(workspace)
    end

    args =
      case args do
        ["--" | rest] -> rest
        other -> other
      end

    # A subcommand is the first non-flag argument, when it names a known
    # entry in the dispatch table. `--help` / `--doctor` still win.
    case split_subcommand(args) do
      {subcommand, rest} ->
        dispatch_subcommand(subcommand, rest)

      nil ->
        run_legacy(args)
    end
  end

  @doc """
  Splits `args` into `{subcommand, rest}` when the first non-flag argument
  names a known subcommand, or `nil` otherwise.
  """
  @spec split_subcommand([String.t()]) :: {String.t(), [String.t()]} | nil
  def split_subcommand(args) do
    case Enum.split_while(args, &String.starts_with?(&1, "-")) do
      {_flags, []} ->
        nil

      {flags, [candidate | rest]} ->
        if Map.has_key?(@subcommands, candidate) do
          {candidate, flags ++ rest}
        else
          nil
        end
    end
  end

  # Every entry in `@subcommands` is currently implemented. When a future
  # command is added to the table before it is wired, `Map.fetch!/2` still
  # resolves it and `apply/3` would raise `UndefinedFunctionError`; the guard
  # below turns that into a clear message instead.
  defp dispatch_subcommand(subcommand, args) do
    %{module: module, fun: fun} = Map.fetch!(@subcommands, subcommand)

    unless function_exported?(module, fun, 1) do
      IO.puts(
        Yoke.CLI.Formatter.format_warning(
          "`yoke #{subcommand}` is not implemented yet. See docs/CI_PLAN.md §6."
        )
      )

      halt(2)
    end

    code = apply(module, fun, [args])
    halt(code)
  end

  defp run_legacy(args) do
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
          languages: :string,
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
          l: :languages,
          u: :update,
          d: :doctor,
          h: :help
        ]
      )

    if opts[:languages] do
      langs =
        opts[:languages]
        |> String.split(~r/[,;\s]+/, trim: true)
        |> Enum.map(&Yoke.Practices.sanitize_language/1)
        |> Enum.reject(&(&1 == ""))

      Application.put_env(:yoke, :project_languages, langs)
    end

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
    session_id = opts[:conversation] || opts[:resume] || generate_uuid()

    session_opts = [session_id: session_id]

    session_opts =
      if opts[:model] do
        Keyword.put(session_opts, :model, opts[:model])
      else
        session_opts
      end

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

  @doc false
  def configure_ragex_ai do
    ai_cfg = Application.get_env(:ragex, :ai, [])
    Application.put_env(:ragex, :ai, Keyword.put(ai_cfg, :providers, []))
  end

  @doc false
  def configure_exla do
    gpu_mem_fraction =
      case System.get_env("EXLA_GPU_MEMORY_FRACTION") do
        nil ->
          0.25

        val ->
          case Float.parse(val) do
            {f, _} -> f
            :error -> 0.25
          end
      end

    gpu_preallocate = System.get_env("EXLA_GPU_PREALLOCATE") in ["true", "1"]

    existing_clients = Application.get_env(:exla, :clients, [])

    cuda_opts =
      Keyword.get(existing_clients, :cuda, platform: :cuda)
      |> Keyword.put_new(:preallocate, gpu_preallocate)
      |> Keyword.put_new(:memory_fraction, gpu_mem_fraction)

    rocm_opts =
      Keyword.get(existing_clients, :rocm, platform: :rocm)
      |> Keyword.put_new(:preallocate, gpu_preallocate)
      |> Keyword.put_new(:memory_fraction, gpu_mem_fraction)

    clients =
      existing_clients
      |> Keyword.put(:cuda, cuda_opts)
      |> Keyword.put(:rocm, rocm_opts)
      |> Keyword.put_new(:tpu, platform: :tpu)
      |> Keyword.put_new(:host, platform: :host)

    Application.put_env(:exla, :clients, clients)
  end

  defp print_usage do
    IO.puts("""
    Yoke (Yoke) — CLI Agentic Framework in Elixir

    USAGE:
      yoke                             Launch interactive REPL mode
      yoke -c <conversation_id>        Resume existing conversation
      yoke "Your prompt here"          One-shot mode
      yoke --prompt "Your prompt"      One-shot mode with flags
      yoke --model deepseek-flash      Specify model (deepseek-flash, deepseek-v4-pro, or deepseek-reasoner)
      yoke --node brain_1 --connect hands@127.0.0.1   Distributed Brain/Hands mode
      yoke --plugin path/to/plugin.exs Load custom plugin on startup

    OPTIONS:
      -c, --conversation STRING  Resume specific conversation ID
      -p, --prompt STRING        Input prompt to send to agent
      -m, --model STRING         Model selection (deepseek-flash, deepseek-v4-pro, deepseek-reasoner, deepseek-v4-flash-vision-exp)
          --node STRING          Start local Erlang distributed node name
          --connect STRING       Connect to remote Hands node
          --plugin FILE          Load external Elixir plugin file (.ex or .exs)
      -h, --help                 Display this help message
    """)
  end
end
