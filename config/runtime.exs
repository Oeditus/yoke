import Config

# Install Yoke's log formatter before any application starts.
#
# `runtime.exs` is evaluated before OTP starts the dependency tree, whereas
# `Yoke.Application.start/2` runs *after* `:ragex` and `:dllb` have already
# booted. Those two emit ~13 `[info]` lines during their own startup, which
# without this would appear raw -- timestamps and `[info]` tags included -- in
# front of every command's output. That is tolerable in a REPL and unacceptable
# in a CI log.
#
# `Yoke.CLI.LogFormatter.install/0` is idempotent, so `Yoke.Application.start/2`
# calling it again is harmless.
if Code.ensure_loaded?(Yoke.CLI.LogFormatter) do
  Yoke.CLI.LogFormatter.install()
end

# Disable automatic AI provider validation in Ragex when embedded in Yoke.
# Yoke manages its own LLM clients (DeepSeekAPI) and uses Ragex for graph/tools/embeddings.
config :ragex, :ai, providers: []

# Configure EXLA GPU memory allocation: avoid grabbing all VRAM up front.
# Restrict GPU preallocation and cap memory fraction to 1/4 (0.25) so concurrent
# instances can start without exhausting GPU memory.
#
# Use the build-time feature setting from config.exs: ordinary tests and all
# escript builds exclude the native dependency tree, so configuring :exla emits
# "Please ensure :exla exists or remove the configuration" on every boot.
if Application.get_env(:yoke, :embeddings_enabled, false) do
  if Code.ensure_loaded?(Yoke.CudaDetector) and Yoke.CudaDetector.cuda_available?() do
    config :ragex, :exla_client, :cuda
  end

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
end
