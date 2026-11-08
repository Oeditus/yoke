test_history_path =
  Path.join(System.tmp_dir!(), "yoke_test_history_#{System.unique_integer([:positive])}")

Application.put_env(:yoke, :history_file, test_history_path)
Application.put_env(:yoke, :auto_start_ragex, false)
Application.put_env(:yoke, :system_halt_enabled, false)
Application.put_env(:yoke, :god_mode, true)

if Application.get_env(:yoke, :embeddings_enabled, false) do
  Application.put_env(:nx, :default_backend, Nx.BinaryBackend)
  Application.put_env(:exla, :start_log_sink, false)
end

# `mix test --no-start` skips `app.start`, so `Yoke.Supervisor` and everything
# under it (`Yoke.Registry`, `Yoke.Brain.SessionSupervisor`, the TaskEngine,
# the InteractionServer, ...) is absent. Any test that starts a session actor
# or executes a tool then dies with
#
#     ** (EXIT) no process: the process is not alive or there's no process
#     currently associated with the given name, possibly because its
#     application isn't started
#
# which is indistinguishable from a real regression: `--no-start` produced 118
# such failures, burying the one or two genuine ones. Tests that need the tree
# are tagged `@moduletag :app`, and `--no-start` excludes that tag here so the
# remaining tests still run and still report honestly.
#
# `:ragex` and `:skip_in_gha` are excluded on CI for the reasons documented in
# `docs/CI_PLAN.md`; the two exclusions compose.
excluded =
  []
  |> then(fn acc ->
    if "--no-start" in System.argv(), do: [:app | acc], else: acc
  end)
  |> then(fn acc ->
    if System.get_env("CI") || System.get_env("GITHUB_ACTIONS"),
      do: [:ragex, :skip_in_gha | acc],
      else: acc
  end)

if excluded != [] do
  ExUnit.configure(exclude: excluded)
end

ExUnit.start()
Code.require_file("support/review_fixture.ex", __DIR__)
Code.require_file("support/stub_interaction.ex", __DIR__)
Code.require_file("support/golden_fixtures.ex", __DIR__)
