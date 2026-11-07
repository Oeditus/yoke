defmodule Yoke.CI.Rag do
  @moduledoc """
  Headless `yoke rag` — optional Ragex code intelligence in CI
  (`docs/CI_PLAN.md` Milestone 2, the `with-ragex` path deferred from §4.2).

  Ragex builds a knowledge graph of the repository (symbols, references, call
  edges) that makes the review turn's `grep`/`read` tools far more effective.
  It is **opt-in** because it is expensive: starting it spawns a
  `dllb-server` process and downloads an embedding model, which is 2–4 minutes
  on a cold runner.

  ## Why this is a separate command

  `yoke review` deliberately does **not** start Ragex (§4.2): a diff review over
  revision-pinned tools gets little benefit for a large fixed cost. `yoke rag`
  exists so a repository that *does* want the graph can build and warm it in a
  dedicated, cacheable step:

  ```yaml
  - uses: actions/cache@v4
    with:
      path: .ragex
      key: ragex-${{ hashFiles('**/*.ex', '**/*.exs', 'mix.lock') }}
  - run: yoke rag --index
  ```

  ## Failure is not fatal

  Ragex is an *enhancement*. If it cannot start (no `dllb-server`, no model,
  no network), this command reports that and exits `0` — a review that would
  have been merely slower must not fail because an optional accelerator was
  unavailable. Pass `--strict` to make it exit non-zero instead.
  """

  alias Yoke.MCP.ServerManager

  @doc """
  Starts Ragex for `cwd` and waits for indexing to finish.

  `opts`:

    * `:cwd` -- repository root (default `File.cwd!()`)
    * `:timeout` -- indexing timeout in ms (default 600_000)

  Returns `{:ok, %{status: :ready | :unavailable, reason: nil | String.t()}}`.
  """
  @spec index(keyword()) :: {:ok, map()}
  def index(opts \\ []) do
    cwd = Keyword.get(opts, :cwd) || File.cwd!()
    timeout = Keyword.get(opts, :timeout, 600_000)

    result =
      try do
        case ServerManager.start_ragex(target_dir: cwd) do
          {:ok, _} ->
            _ = ServerManager.await_ragex(timeout)
            %{status: :ready, reason: nil}

          {:error, reason} ->
            %{status: :unavailable, reason: to_string(reason)}

          other ->
            %{status: :unavailable, reason: inspect(other)}
        end
      rescue
        e -> %{status: :unavailable, reason: Exception.message(e)}
      catch
        kind, reason -> %{status: :unavailable, reason: inspect({kind, reason})}
      end

    {:ok, result}
  end

  @doc """
  Reports whether Ragex is currently running for `cwd` without starting it.

  Returns `{:ok, %{running: boolean, graph_present: boolean}}`. `graph_present`
  reflects whether a `.ragex` directory exists, which is what a restored CI
  cache would leave behind.
  """
  @spec status(String.t()) :: {:ok, map()}
  def status(cwd \\ ".") do
    running =
      try do
        Enum.any?(ServerManager.list_servers(), fn server ->
          to_string(Map.get(server, :name, "")) =~ "ragex"
        end)
      rescue
        _ -> false
      catch
        _, _ -> false
      end

    {:ok, %{running: running, graph_present: File.dir?(Path.join(cwd, ".ragex"))}}
  end

  @doc """
  Stops Ragex, releasing the `dllb-server` process and flushing the graph.

  Always safe to call, even if Ragex was never started.
  """
  @spec stop() :: :ok
  def stop do
    _ = ServerManager.stop_ragex()
    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end
end
