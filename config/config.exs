import Config

# Configure dllb client application
config :dllb,
  enabled: true,
  host: System.get_env("DLLB_HOST", "127.0.0.1"),
  port: String.to_integer(System.get_env("DLLB_PORT", "3009")),
  pool_size: String.to_integer(System.get_env("DLLB_POOL_SIZE", "30")),
  timeout: :infinity

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
# Skipped entirely under the `escript` Mix env, which deliberately excludes
# exla/nx/bumblebee/image from the dependency tree (see mix.exs) so the
# standalone `yoke` escript doesn't try to load an unloadable NIF.
if config_env() != :escript do
  config :exla, start_log_sink: false
  config :nx, :default_backend, Nx.BinaryBackend
end

if config_env() == :test do
  config :yoke, auto_start_ragex: false
  config :dllb, enabled: false
  config :nx, :default_backend, Nx.BinaryBackend
  config :exla, start_log_sink: false
  config :logger, level: :warning
end
