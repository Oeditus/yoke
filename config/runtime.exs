import Config

# Disable automatic AI provider validation in Ragex when embedded in Yoke.
# Yoke manages its own LLM clients (DeepSeekAPI) and uses Ragex for graph/tools/embeddings.
config :ragex, :ai, providers: []

# Configure EXLA GPU memory allocation: avoid grabbing all VRAM up front.
# Restrict GPU preallocation and cap memory fraction to 1/4 (0.25) so concurrent
# instances can start without exhausting GPU memory.
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
