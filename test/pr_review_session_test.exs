defmodule Yoke.PRReview.SessionTest do
  use ExUnit.Case, async: false
  @moduletag :tmp_dir
  alias Yoke.Brain.Session
  alias Yoke.PRReview.Context
  alias Yoke.Test.ReviewFixture, as: Fixture

  setup %{tmp_dir: dir} do
    {:ok, _} = Application.ensure_all_started(:req)

    for {name, keys} <- [
          {Yoke.Registry, :unique},
          {Yoke.PubSubRegistry, :duplicate},
          {Yoke.TaskEngine.TaskRegistry, :duplicate},
          {Yoke.TaskEngine.LockRegistry, :unique},
          {Yoke.PackageRegistry, :duplicate}
        ] do
      unless Process.whereis(name),
        do: start_supervised!({Registry, keys: keys, name: name}, id: name)
    end

    unless Process.whereis(Yoke.TaskEngine.TaskSupervisor),
      do: start_supervised!({Task.Supervisor, name: Yoke.TaskEngine.TaskSupervisor})

    unless Process.whereis(Yoke.Plugin.Loader), do: start_supervised!(Yoke.Plugin.Loader)
    Fixture.repository(Path.join(dir, "repo"))
  end

  defp session(repo, responses, opts \\ []) do
    {listen, server, endpoint} = Fixture.provider(self(), responses)

    on_exit(fn ->
      :gen_tcp.close(listen)
      if Process.alive?(server), do: Process.exit(server, :kill)
    end)

    pid =
      start_supervised!(
        {Session,
         Keyword.merge(
           [
             session_id: "review-test-#{System.unique_integer([:positive])}",
             cwd: repo,
             api_key: "",
             model: "review-test",
             endpoint: endpoint,
             max_tool_depth: 8
           ],
           opts
         )}
      )

    pid
  end

  test "fresh review input excludes old conversation, preserves it afterward, and stays read-only",
       %{repo: repo} do
    pid = session(repo, [Fixture.choice("<findings>[]</findings>")])
    old = %{"role" => "user", "content" => "UNRELATED HISTORICAL REVIEW AND INSTRUCTIONS"}
    :sys.replace_state(pid, &%{&1 | messages: &1.messages ++ [old]})
    File.write!(Path.join(repo, ".yokerules"), "CURRENT PROJECT REVIEW GUIDANCE")
    assert {:ok, context} = Context.resolve("main feature", repo)

    assert {:ok, %{content: "<findings>[]</findings>"}} =
             Session.generate_code_review(pid, "main", "feature", review_context: context)

    assert_receive {:review_request, request}, 5_000
    assert [system, user] = request["messages"]
    assert system["content"] =~ "read-only code reviewer"
    assert user["content"] =~ context.head_sha
    assert user["content"] =~ context.raw_diff
    assert user["content"] =~ "CURRENT PROJECT REVIEW GUIDANCE"
    refute user["content"] =~ old["content"]
    names = Enum.map(request["tools"], &get_in(&1, ["function", "name"]))
    assert "read_file" in names
    assert "git_diff" in names
    refute "bash" in names
    refute "write_file" in names
    assert {:ok, messages} = Session.get_messages(pid)
    assert old in messages
    assert List.last(messages)["content"] == "<findings>[]</findings>"
    refute Enum.any?(messages, &String.contains?(&1["content"], "<review_diff>"))
  end

  test "supporting tools read pinned content, not dirty checkout state", %{repo: repo} do
    pid =
      session(repo, [
        Fixture.tool_choice("read_file", %{"path" => "sample.ex"}),
        Fixture.choice("<findings>[]</findings>")
      ])

    File.write!(Path.join(repo, "sample.ex"), "UNRELATED DIRTY CONTENT\n")
    assert {:ok, _} = Session.generate_code_review(pid, "main", "feature")
    assert_receive {:review_request, _}, 5_000
    assert_receive {:review_request, second}, 5_000
    tool = Enum.find(second["messages"], &(&1["role"] == "tool"))
    assert tool["content"] == "reviewed_value\n"
    refute tool["content"] =~ "UNRELATED"
  end

  test "unadvertised mutation calls are blocked even if a provider fabricates them", %{repo: repo} do
    pid =
      session(
        repo,
        [
          Fixture.tool_choice("write_file", %{"path" => "sample.ex", "content" => "MUTATED"}),
          Fixture.choice("<findings>[]</findings>")
        ],
        permission_mode: :auto_approve
      )

    assert {:ok, _} = Session.generate_code_review(pid, "main", "feature")
    assert File.read!(Path.join(repo, "sample.ex")) == "reviewed_value\n"
    assert_receive {:review_request, _}, 5_000
    assert_receive {:review_request, second}, 5_000
    tool = Enum.find(second["messages"], &(&1["role"] == "tool"))
    assert tool["content"] =~ "unavailable"
  end

  test "malformed, unrelated, off-diff and truncated outputs are errors, not clean reviews", %{
    repo: repo
  } do
    for {content, finish} <- [
          {"No missing tests or bugs found.", "stop"},
          {"<findings>[broken]</findings>", "stop"},
          {"```json\n[{\"setting\":true}]\n```", "stop"},
          {"<findings>[]</findings>", "length"},
          {"<findings>[]</findings>", "content_filter"},
          {"<findings>" <>
             Yoke.Json.encode!([
               %{
                 file: "unrelated.ex",
                 line: 1,
                 title: "Unrelated",
                 description: "Not part of this diff",
                 severity: "high"
               }
             ]) <> "</findings>", "stop"}
        ] do
      pid = session(repo, [Fixture.choice(content, finish)])
      assert {:ok, before} = Session.get_messages(pid)
      assert {:error, reason} = Session.generate_code_review(pid, "main", "feature")
      assert is_binary(reason)
      assert {:ok, ^before} = Session.get_messages(pid)
      stop_supervised!(Session)
      assert_receive {:review_request, _}, 5_000
    end
  end

  test "review refuses canned offline output and empty branch ranges", %{repo: repo} do
    assert {:error, reason} =
             Yoke.Client.DeepSeekAPI.validate_live_config(
               api_key: "",
               endpoint: "https://provider.example.invalid/chat/completions",
               mock: false
             )

    assert reason =~ "canned offline"
    pid = session(repo, [])
    assert {:error, empty} = Session.generate_code_review(pid, "HEAD", "HEAD")
    assert empty =~ "No committed changes"
    refute_receive {:review_request, _}
  end

  test "review tool limits stop without silently continuing forever", %{repo: repo} do
    pid =
      session(repo, [Fixture.tool_choice("read_file", %{"path" => "sample.ex"})],
        max_tool_depth: 1
      )

    assert {:error, reason} = Session.generate_code_review(pid, "main", "feature")
    assert reason =~ "tool limit"
  end

  test "changing unused arguments cannot repeat immutable reads until the CI budget expires", %{
    repo: repo
  } do
    reads =
      for attempt <- 1..4 do
        Fixture.tool_choice("read_file", %{"path" => "sample.ex", "attempt" => attempt})
      end

    pid = session(repo, reads ++ [Fixture.choice("<findings>[]</findings>")])
    assert {:ok, _} = Session.generate_code_review(pid, "main", "feature")

    for _ <- 1..4, do: assert_receive({:review_request, _}, 5_000)
    assert_receive {:review_request, final}, 5_000
    assert Map.get(final, "tools", []) == []
    assert List.last(final["messages"])["content"] =~ "no new evidence"
    refute_receive {:review_request, _}
  end

  test "advancing past EOF is bounded even though every call has a different range", %{repo: repo} do
    reads =
      for start <- [100, 200, 300, 400] do
        Fixture.tool_choice("read_file", %{
          "path" => "sample.ex",
          "start_line" => start,
          "end_line" => start + 50
        })
      end

    pid = session(repo, reads ++ [Fixture.choice("<findings>[]</findings>")])
    assert {:ok, _} = Session.generate_code_review(pid, "main", "feature")
    for _ <- 1..4, do: assert_receive({:review_request, _}, 5_000)
    assert_receive {:review_request, final}, 5_000
    assert Map.get(final, "tools", []) == []

    results = Enum.filter(final["messages"], &(&1["role"] == "tool"))
    assert [_, _, _, _] = results
    assert Enum.all?(results, &String.contains?(&1["content"], "past end of file"))
  end

  test "advancing past EOF alternating with non-read tools is bounded and finalizes", %{
    repo: repo
  } do
    calls = [
      Fixture.tool_choice("read_file", %{
        "path" => "sample.ex",
        "start_line" => 100,
        "end_line" => 150
      }),
      Fixture.tool_choice("grep_search", %{"query" => "missing"}),
      Fixture.tool_choice("read_file", %{
        "path" => "sample.ex",
        "start_line" => 200,
        "end_line" => 250
      }),
      Fixture.tool_choice("grep_search", %{"query" => "missing"}),
      Fixture.tool_choice("read_file", %{
        "path" => "sample.ex",
        "start_line" => 300,
        "end_line" => 350
      }),
      Fixture.tool_choice("read_file", %{
        "path" => "sample.ex",
        "start_line" => 400,
        "end_line" => 450
      })
    ]

    pid = session(repo, calls ++ [Fixture.choice("<findings>[]</findings>")])
    assert {:ok, _} = Session.generate_code_review(pid, "main", "feature")
    for _ <- 1..6, do: assert_receive({:review_request, _}, 5_000)
    assert_receive {:review_request, final}, 5_000
    assert Map.get(final, "tools", []) == []
  end

  test "identical review loops finalize without asking a headless user for permission", %{
    repo: repo
  } do
    read = Fixture.tool_choice("read_file", %{"path" => "sample.ex"})
    pid = session(repo, [read, read, read, read, Fixture.choice("<findings>[]</findings>")])
    assert {:ok, _} = Session.generate_code_review(pid, "main", "feature")
    for _ <- 1..4, do: assert_receive({:review_request, _}, 5_000)
    assert_receive {:review_request, final}, 5_000
    assert Map.get(final, "tools", []) == []
    assert List.last(final["messages"])["content"] =~ "after a loop warning"
  end

  test "a provider ignoring tool-free finalization fails closed instead of executing more reads",
       %{
         repo: repo
       } do
    reads =
      for attempt <- 1..5 do
        Fixture.tool_choice("read_file", %{"path" => "sample.ex", "attempt" => attempt})
      end

    pid = session(repo, reads)
    assert {:ok, before} = Session.get_messages(pid)
    assert {:error, reason} = Session.generate_code_review(pid, "main", "feature")
    assert reason =~ "continued requesting tools"
    assert {:ok, ^before} = Session.get_messages(pid)
    for _ <- 1..5, do: assert_receive({:review_request, _}, 5_000)
    refute_receive {:review_request, _}
  end

  test "successive ranges returning fresh evidence do not trip review progress protection", %{
    repo: repo
  } do
    File.write!(Path.join(repo, "sample.ex"), Enum.map_join(1..6, "\n", &"value_#{&1}") <> "\n")
    Fixture.commit(repo, "Expand sample")

    reads =
      for line <- 1..6 do
        Fixture.tool_choice("read_file", %{
          "path" => "sample.ex",
          "start_line" => line,
          "end_line" => line
        })
      end

    pid = session(repo, reads ++ [Fixture.choice("<findings>[]</findings>")])
    assert {:ok, _} = Session.generate_code_review(pid, "main", "feature")
    for _ <- 1..6, do: assert_receive({:review_request, _}, 5_000)
    assert_receive {:review_request, final}, 5_000
    assert [_ | _] = final["tools"]
    refute List.last(final["messages"])["content"] =~ "no new evidence"
  end

  test "background notices and model changes survive review completion while concurrent turns are refused",
       %{repo: repo} do
    owner = self()

    wait = fn ->
      send(owner, {:provider_waiting, self()})

      receive do
        :release -> Fixture.choice("<findings>[]</findings>")
      end
    end

    pid = session(repo, [wait])
    task = Task.async(fn -> Session.generate_code_review(pid, "main", "feature") end)
    assert_receive {:provider_waiting, server}, 5_000
    assert {:error, busy} = Session.generate_code_review(pid, "main", "feature")
    assert busy =~ "already running"
    assert {:error, _} = Session.send_user_message(pid, "Do something else")
    assert {:ok, "new-model"} = Session.set_model(pid, "new-model")
    send(pid, {:job_completed, "job-test", "test command", {:exited, 0}, "Background output"})
    assert {:ok, during} = Session.get_messages(pid)
    assert Enum.any?(during, &String.contains?(&1["content"], "Background output"))
    send(server, :release)
    assert {:ok, _} = Task.await(task, 5_000)
    assert {:ok, after_review} = Session.get_messages(pid)
    assert Enum.any?(after_review, &String.contains?(&1["content"], "Background output"))
    assert {:ok, "new-model"} = Session.get_model(pid)
  end

  test "cancelling a review preserves original conversation and does not persist partial evidence",
       %{repo: repo} do
    owner = self()

    wait = fn ->
      send(owner, :provider_waiting)

      receive do
        :release -> Fixture.choice("<findings>[]</findings>")
      end
    end

    pid = session(repo, [wait])
    assert {:ok, before} = Session.get_messages(pid)
    task = Task.async(fn -> Session.generate_code_review(pid, "main", "feature") end)
    assert_receive :provider_waiting, 5_000
    assert :ok = Session.cancel_current_turn(pid)
    assert {:error, reason} = Task.await(task, 5_000)
    assert reason =~ "cancelled"
    assert {:ok, ^before} = Session.get_messages(pid)
    assert Session.get_info(pid).status == :idle
  end

  test "the actor refuses fix turns for a different execution checkout", %{repo: repo} do
    pid = session(repo, [])
    assert {:ok, context} = Context.resolve("main feature", repo)
    assert {:error, reason} = Session.apply_review_fixes(pid, context, "Fix these findings")
    assert reason =~ "repository root"
    refute_receive {:review_request, _}
  end

  test "both command aliases report the same empty-range error", %{repo: repo} do
    pid = session(repo, [])

    for command <- ["/cr HEAD HEAD", "/review HEAD HEAD"] do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert :continue = Yoke.CLI.Repl.handle_input(command, pid, "test")
        end)

      assert output =~ "No committed changes"
    end
  end
end
