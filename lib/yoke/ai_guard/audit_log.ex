defmodule Yoke.AIGuard.AuditLog do
  @moduledoc """
  Single-writer JSONL audit sink for `Yoke.AIGuard`.

  ## Why a process

  The audit trail used to be appended directly from whichever process happened
  to call `Yoke.AIGuard.guard_tool/3` or `guard_llm/3`:

      File.mkdir_p!(Path.dirname(path))
      File.write!(path, line, [:append])

  Two problems followed from that. First, the path was relative
  (`.yoke/logs/ai_guard_audit.jsonl`) and therefore resolved against the VM's
  working directory rather than the session's `cwd`, so a session running in a
  different workspace wrote its audit trail into the wrong tree -- silently,
  because the surrounding `rescue` swallowed every failure. Second, `guard_tool/3`
  runs on *every* tool call, and `Yoke.TaskEngine.Orchestrator.execute_batch/3`
  executes tool calls concurrently, so two workers could interleave partial
  lines and corrupt the JSONL.

  This process owns the file. Callers `cast` a fully-encoded line; the writer
  appends whole lines one at a time. Appends are batched per mailbox drain so a
  burst of tool calls costs one file open rather than one per call.

  ## Degraded mode

  When the process is not running (unit tests, `mix test --no-start`, or a
  caller that never started the application), `append/3` returns `:ok` without
  touching disk. An audit trail is diagnostics, not a correctness requirement,
  and a missing writer must never turn a guarded tool call into a crash.
  """

  use GenServer
  require Logger

  @audit_file ".yoke/logs/ai_guard_audit.jsonl"

  @doc "Returns the repo-relative audit log path."
  @spec audit_file() :: String.t()
  def audit_file, do: @audit_file

  @doc "Returns the absolute audit log path for `cwd`."
  @spec path(String.t()) :: String.t()
  def path(cwd \\ "."), do: Path.join(cwd, @audit_file)

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Appends one already-encoded JSON line to the audit log for `cwd`.

  Never raises and never blocks the caller on I/O: the entry is handed to the
  writer process and written on its own time.
  """
  @spec append(String.t(), iodata()) :: :ok
  def append(cwd, line) do
    case Process.whereis(__MODULE__) do
      nil ->
        :ok

      pid ->
        GenServer.cast(pid, {:append, cwd, IO.iodata_to_binary(line)})
        :ok
    end
  catch
    _, _ -> :ok
  end

  @doc """
  Reads every decodable entry from the audit log for `cwd`, oldest first.

  Returns `[]` when the file does not exist or nothing decodes.
  """
  @spec read(String.t()) :: [map()]
  def read(cwd \\ ".") do
    file = path(cwd)

    if File.exists?(file) do
      file
      |> File.stream!()
      |> Enum.flat_map(fn line ->
        case Yoke.Json.decode(line) do
          {:ok, map} when is_map(map) -> [map]
          _ -> []
        end
      end)
    else
      []
    end
  rescue
    _ -> []
  end

  # Server callbacks

  @impl true
  def init(_opts) do
    {:ok, %{}}
  end

  @impl true
  def handle_cast({:append, cwd, line}, state) do
    # Drain whatever else arrived in the same mailbox drain so a burst of tool
    # calls costs one open/close per batch instead of one per entry.
    write_batch(cwd, [line | drain([])])
    {:noreply, state}
  end

  defp write_batch(cwd, batch) do
    file = path(cwd)

    with :ok <- File.mkdir_p(Path.dirname(file)),
         {:ok, io} <- File.open(file, [:append, :binary]) do
      try do
        Enum.each(batch, &IO.binwrite(io, &1))
      after
        File.close(io)
      end

      :ok
    else
      {:error, reason} ->
        Logger.debug("[AIGuard.AuditLog] Cannot write #{file}: #{inspect(reason)}")
        :error
    end
  end

  # Collects every entry already queued in this process's mailbox so a burst of
  # tool calls costs one open/close rather than one per entry.
  defp drain(acc) do
    receive do
      {:"$gen_cast", {:append, _cwd, line}} -> drain([line | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
