defmodule Yoke.ReplStateFeedbackTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO
  alias Yoke.CLI.Repl

  defmodule ReplySession do
    use GenServer
    def start_link(replies), do: GenServer.start_link(__MODULE__, replies)
    @impl true
    def init(replies), do: {:ok, replies}
    @impl true
    def handle_call(request, _from, [{expected, reply} | rest]) do
      if request != expected, do: raise("Unexpected session request: #{inspect(request)}")
      {:reply, reply, rest}
    end
  end

  defp session(replies), do: start_supervised!({ReplySession, replies})

  test "compact reports current context estimates, not cumulative billing" do
    pid =
      session([
        {:get_token_stats, %{context_tokens: 200, total_tokens: 50_000}},
        {:compact_context, {:ok, "Short summary"}},
        {:get_token_stats, %{context_tokens: 80, total_tokens: 50_000}}
      ])

    output = capture_io(fn -> assert :continue = Repl.handle_input("/compact", pid, "test") end)
    assert output =~ "Estimated current context tokens: 200 -> 80 (-60.0%)"
    refute output =~ "50000"
  end

  test "compact shows a signed increase and guards zero starting tokens" do
    for {before_tokens, after_tokens, percent} <- [{100, 125, "+25.0%"}, {0, 0, "+0.0%"}] do
      {:ok, pid} =
        ReplySession.start_link([
          {:get_token_stats, %{context_tokens: before_tokens}},
          {:compact_context, {:ok, "No history to compress."}},
          {:get_token_stats, %{context_tokens: after_tokens}}
        ])

      try do
        output = capture_io(fn -> Repl.handle_input("/compact", pid, "test") end)
        assert output =~ percent
      after
        GenServer.stop(pid)
      end
    end
  end

  test "failed compaction reports the error without requesting after statistics" do
    pid =
      session([{:get_token_stats, %{context_tokens: 10}}, {:compact_context, {:error, "failed"}}])

    output = capture_io(fn -> Repl.handle_input("/compact", pid, "test") end)
    assert output =~ "failed"
    refute output =~ "successfully compressed"
  end

  test "checkpoint without arguments lists metadata and never saves" do
    pid = session([{:list_checkpoints, [%{id: "cp_1", label: "before", turn: 3}]}])

    output =
      capture_io(fn -> assert :continue = Repl.handle_input("/checkpoint", pid, "test") end)

    assert output =~ "ID: cp_1 | label: before | turn: 3"
    assert :sys.get_state(pid) == []
  end

  test "blank checkpoint argument lists rather than saving an implicit snapshot" do
    pid = session([{:list_checkpoints, []}])
    output = capture_io(fn -> Repl.handle_input("/checkpoint   ", pid, "test") end)
    assert output =~ "Use /checkpoint <label>"
    assert :sys.get_state(pid) == []
  end

  test "labelled checkpoints render ID label and turn" do
    pid =
      session([
        {{:checkpoint, "before refactor"},
         {:ok, %{id: "cp_2", label: "before refactor", turn: 4}}}
      ])

    output = capture_io(fn -> Repl.handle_input("/checkpoint before refactor", pid, "test") end)
    assert output =~ "'before refactor' (ID: cp_2, turn: 4)"
  end

  test "checkpoint failures and unexpected replies do not crash the REPL" do
    for reply <- [{:error, :eacces}, :unexpected, {:ok, %{}}] do
      {:ok, pid} = ReplySession.start_link([{{:checkpoint, "save"}, reply}])

      try do
        output =
          capture_io(fn ->
            assert :continue = Repl.handle_input("/checkpoint save", pid, "test")
          end)

        assert output =~
                 if(match?({:error, _}, reply),
                   do: "Could not save checkpoint",
                   else: "Unexpected checkpoint reply"
                 )
      after
        GenServer.stop(pid)
      end
    end
  end

  test "checkpoint prefix typos do not save snapshots" do
    output = capture_io(fn -> Repl.handle_input("/checkpointoops", nil, "test") end)
    assert output =~ "Unknown command"
  end

  test "checkpoint and undo contextual help explain state-only restoration" do
    assert Yoke.CLI.Help.text("checkpoint") =~ "List saved checkpoint IDs"
    assert Yoke.CLI.Help.text("checkpoint") =~ "/checkpoint <label>"
    assert Yoke.CLI.Help.text("undo") =~ "Working-tree files are unchanged"
  end
end
