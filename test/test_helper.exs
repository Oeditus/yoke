test_history_path =
  Path.join(System.tmp_dir!(), "yoke_test_history_#{System.unique_integer([:positive])}")

Application.put_env(:yoke, :history_file, test_history_path)
Application.put_env(:yoke, :auto_start_ragex, false)
Application.put_env(:yoke, :system_halt_enabled, false)
Application.put_env(:yoke, :god_mode, true)
Application.put_env(:nx, :default_backend, Nx.BinaryBackend)
Application.put_env(:exla, :start_log_sink, false)

if System.get_env("CI") || System.get_env("GITHUB_ACTIONS") do
  ExUnit.configure(exclude: [ragex: true])
end

ExUnit.start()
Code.require_file("support/review_fixture.ex", __DIR__)
