import Config

# Configure dllb client application
config :dllb,
  enabled: true,
  host: System.get_env("DLLB_HOST", "127.0.0.1"),
  port: String.to_integer(System.get_env("DLLB_PORT", "3009")),
  pool_size: String.to_integer(System.get_env("DLLB_POOL_SIZE", "30")),
  timeout: :infinity

# Configure yoke global defaults
config :yoke,
  assistant_name: "Robby Ott",
  # The blocking seam (`docs/CI_PLAN.md` §2.1): which module answers every
  # "stop and ask a human" site in the agent loop. `Yoke.Interaction.TTY` is
  # the interactive REPL; CI swaps in `Yoke.Interaction.Policy`, which never
  # blocks. Selected once here so no call site branches per call.
  interaction: Yoke.Interaction.TTY,
  # The presentation seam (§2.2). `:auto` probes the environment on first
  # use; `:tty` / `:plain` force a mode (tests, `yoke --doctor`).
  output_mode: :auto

# Configure ragex knowledge graph store backend to use per-project dllb server daemon
# Disable stdio server when embedded in yoke to prevent raw JSON-RPC dumps
config :ragex,
  store_backend: :dllb,
  dllb_mode: :per_project,
  start_stdio_server: false

# Disable automatic AI provider validation in Ragex when embedded in Yoke.
# Yoke manages its own LLM clients (DeepSeekAPI) and uses Ragex for graph/tools/embeddings.
config :ragex, :ai, providers: []

# Configure EXLA to disable log sink when NIF is uncompiled/unavailable.
# Restrict GPU memory allocation: avoid grabbing all VRAM at once (default to 1/4
# memory fraction without eager preallocation) so multiple instances can run concurrently.
# Skipped entirely under the `escript` Mix env, which deliberately excludes
# exla/nx/bumblebee/image from the dependency tree (see mix.exs) so the
# standalone `yoke` escript doesn't try to load an unloadable NIF.
if config_env() != :escript do
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

  config :exla,
    start_log_sink: false,
    clients: [
      cuda: [platform: :cuda, preallocate: gpu_preallocate, memory_fraction: gpu_mem_fraction],
      rocm: [platform: :rocm, preallocate: gpu_preallocate, memory_fraction: gpu_mem_fraction],
      tpu: [platform: :tpu],
      host: [platform: :host]
    ]

  config :nx, :default_backend, Nx.BinaryBackend
end

if config_env() == :test do
  config :yoke, auto_start_ragex: false
  config :dllb, enabled: false
  config :ragex, store_backend: :ets
  config :nx, :default_backend, Nx.BinaryBackend
  config :exla, start_log_sink: false
  config :logger, level: :warning
end

# Bake Yoke's log formatter into the `:logger` default handler at *build* time.
#
# This matters only for the `escript` env. An escript archive starts the
# dependency tree (`:ragex`, `:dllb`) before `config/runtime.exs` is evaluated
# and before `Yoke.CLI.Main.main/1` runs, so ~15 raw `[info]`/`[debug]` lines
# with timestamps appear ahead of the command's own output. Installing the
# formatter here puts it in the archive's `logger` app env, so it is in place
# before anything starts.
if config_env() == :escript do
  config :logger,
    default_handler: [formatter: {Yoke.CLI.LogFormatter, %{}}]
end
