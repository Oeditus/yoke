defmodule Yoke.Brain.AgentLoopTest do
  use ExUnit.Case, async: true

  alias Yoke.Brain.AgentLoop

  describe "edit argument identity" do
    test "does not conflate valid edits with different exact content" do
      for {old, new} <- [
            {"value\n", "  value\n"},
            {"value", "value\n"},
            {"{\"a\": 1}", "{\"a\":1}"},
            {"1", 1},
            {"true", true},
            {"null", nil},
            {%{}, []}
          ] do
        messages = [%{"role" => "user", "content" => "Edit"}, edit_step(edit_args(old))]
        call = %{id: "next", name: "mcp_ragex_edit_files", arguments: edit_args(new)}

        assert :ok = AgentLoop.detect_tool_loop(messages, [call]),
               "distinct edit content collapsed: #{inspect({old, new})}"
      end
    end

    test "recognizes identical edits across wire and decoded argument representations" do
      args = edit_args("  value\n")
      messages = [%{"role" => "user", "content" => "Edit"}, edit_step(args)]
      call = %{id: "different-id", name: "mcp_ragex_edit_files", arguments: args}

      assert {:loop, %{period: 1, count: 2}} = AgentLoop.detect_tool_loop(messages, [call])
      refute "mcp_ragex_edit_files" in AgentLoop.repeatable_tools()
    end

    test "canonicalizes object keys without parsing nested JSON-looking strings" do
      args = %{changes: [%{content: "{\"value\": true}\n", line: "1"}]}
      wire = ~s({"changes":[{"line":"1","content":"{\\"value\\": true}\\n"}]})

      assert AgentLoop.normalize_arguments(args) == AgentLoop.normalize_arguments(wire)

      assert %{"changes" => [%{"line" => "1", "content" => "{\"value\": true}\n"}]} =
               AgentLoop.normalize_arguments(wire)
    end

    test "keeps edit array order distinct and trims malformed argument whitespace" do
      refute AgentLoop.normalize_arguments(%{changes: ["first", "second"]}) ==
               AgentLoop.normalize_arguments(%{changes: ["second", "first"]})

      assert AgentLoop.normalize_arguments("invalid ") ==
               AgentLoop.normalize_arguments("invalid")

      refute AgentLoop.normalize_arguments("invalid1") ==
               AgentLoop.normalize_arguments("invalid2")
    end

    test "internal notices retain the current turn but a multimodal user starts a new one" do
      args = edit_args("value")
      call = %{name: "mcp_ragex_edit_files", arguments: args}
      history = [%{"role" => "user", "content" => "Edit"}, edit_step(args)]
      notice = %{"role" => "user", "content" => "SYSTEM NOTICE: Tool failed."}

      assert {:loop, _} = AgentLoop.detect_tool_loop(history ++ [notice], [call])

      user = %{"role" => "user", "content" => [%{"type" => "text", "text" => "Retry"}]}
      assert :ok = AgentLoop.detect_tool_loop(history ++ [notice, user], [call])
    end
  end

  describe "outstanding loop warnings" do
    test "only an immediately preceding loop warning can trigger escalation" do
      warning = %{
        "role" => "user",
        "content" => "SYSTEM NOTICE: Repetitive tool loop detected (period 1)"
      }

      assert AgentLoop.loop_warning_pending?([warning])
      refute AgentLoop.loop_warning_pending?([warning, edit_step(edit_args("progress"))])
      refute AgentLoop.loop_warning_pending?([warning, %{"role" => "tool", "content" => "done"}])
      refute AgentLoop.loop_warning_pending?([warning, %{"role" => "user", "content" => "Retry"}])

      refute AgentLoop.loop_warning_pending?([
               warning,
               %{"role" => "user", "content" => [%{"text" => "New turn"}]}
             ])

      refute AgentLoop.loop_warning_pending?([])
    end
  end

  defp edit_args(content) do
    %{
      "files" => [
        %{
          "path" => "lib/sample.ex",
          "changes" => [
            %{"line_start" => 1, "line_end" => 1, "old_content" => "old", "content" => content}
          ]
        }
      ]
    }
  end

  defp edit_step(args) do
    %{
      "role" => "assistant",
      "tool_calls" => [
        %{
          "id" => "previous",
          "function" => %{
            "name" => "mcp_ragex_edit_files",
            "arguments" => Yoke.Json.encode!(args)
          }
        }
      ]
    }
  end

  describe "AgentLoop duplicate tool call detection" do
    test "allows identical mutable reads to observe refreshed evidence" do
      messages = [
        %{"role" => "user", "content" => "List files"},
        %{
          "role" => "assistant",
          "content" => "",
          "tool_calls" => [
            %{
              "id" => "call_1",
              "function" => %{"name" => "list_dir", "arguments" => "{\"path\":\".\"}"}
            }
          ]
        },
        %{"role" => "tool", "content" => "file1.txt\nfile2.txt"}
      ]

      new_tool_calls = [%{id: "call_2", name: "list_dir", arguments: %{"path" => "."}}]

      refute AgentLoop.duplicate_tool_calls?(messages, new_tool_calls)
    end

    test "returns false when tool calls or arguments differ" do
      messages = [
        %{"role" => "user", "content" => "List files"},
        %{
          "role" => "assistant",
          "content" => "",
          "tool_calls" => [
            %{
              "id" => "call_1",
              "function" => %{"name" => "list_dir", "arguments" => "{\"path\":\".\"}"}
            }
          ]
        }
      ]

      new_tool_calls = [%{id: "call_2", name: "list_dir", arguments: %{"path" => "lib"}}]

      assert AgentLoop.duplicate_tool_calls?(messages, new_tool_calls) == false
    end

    test "does not deduplicate repeatable tools like bash probes across turns" do
      messages = [
        %{"role" => "user", "content" => "Check status"},
        %{
          "role" => "assistant",
          "content" => "",
          "tool_calls" => [
            %{
              "id" => "call_1",
              "function" => %{
                "name" => "bash",
                "arguments" => "{\"command\":\"curl -s http://localhost:4000/health\"}"
              }
            }
          ]
        },
        %{"role" => "tool", "content" => "status: starting"}
      ]

      new_tool_calls = [
        %{
          id: "call_2",
          name: "bash",
          arguments: %{"command" => "curl -s http://localhost:4000/health"}
        }
      ]

      # Probes must be permitted to repeat to observe changing external state (up to 2 times)
      assert AgentLoop.duplicate_tool_calls?(messages, new_tool_calls) == false
    end

    test "detects period 1 loop when repeatable probe repeats 3 or more times" do
      probe_call = %{
        "role" => "assistant",
        "tool_calls" => [
          %{
            "id" => "call_1",
            "function" => %{
              "name" => "bash",
              "arguments" => "{\"command\":\"curl -s http://localhost:4000/health\"}"
            }
          }
        ]
      }

      messages = [
        %{"role" => "user", "content" => "Check status"},
        probe_call,
        %{"role" => "tool", "content" => "status: starting"},
        probe_call,
        %{"role" => "tool", "content" => "status: starting"}
      ]

      new_tool_calls = [
        %{
          id: "call_3",
          name: "bash",
          arguments: %{"command" => "curl -s http://localhost:4000/health"}
        }
      ]

      assert {:loop, loop_info} = AgentLoop.detect_tool_loop(messages, new_tool_calls)
      assert loop_info.period == 1
      assert loop_info.count == 3
      assert AgentLoop.duplicate_tool_calls?(messages, new_tool_calls) == true
    end

    test "detects alternating period 2 tool cycle (e.g. bash wc -l and grep SOUNDNESS.md)" do
      cmd_a =
        "cd /home/am/Proyectos/cure-lang && wc -l /tmp/check-stage8.log && tail -2 /tmp/check-stage8.log"

      cmd_b =
        "cd /home/am/Proyectos/cure-lang && grep -n \"M2a–M2c\" docs/SOUNDNESS.md; sed -n '1580,1591p' docs/SOUNDNESS.md"

      step_a = %{
        "role" => "assistant",
        "tool_calls" => [
          %{
            "id" => "c_a1",
            "function" => %{"name" => "bash", "arguments" => Yoke.Json.encode!(%{command: cmd_a})}
          }
        ]
      }

      step_b = %{
        "role" => "assistant",
        "tool_calls" => [
          %{
            "id" => "c_b1",
            "function" => %{"name" => "bash", "arguments" => Yoke.Json.encode!(%{command: cmd_b})}
          }
        ]
      }

      # 3 previous turns: A, B, A
      messages = [
        %{"role" => "user", "content" => "Check progress on stage 8 soundness"},
        step_a,
        %{"role" => "tool", "content" => "450 /tmp/check-stage8.log\nOK"},
        step_b,
        %{"role" => "tool", "content" => "1580: M2a-M2c passed"},
        step_a,
        %{"role" => "tool", "content" => "450 /tmp/check-stage8.log\nOK"}
      ]

      # Candidate 4th turn: B (completing second full cycle of [A, B])
      candidate_call = [
        %{id: "c_b2", name: "bash", arguments: %{"command" => cmd_b}}
      ]

      assert {:loop, loop_info} = AgentLoop.detect_tool_loop(messages, candidate_call)
      assert loop_info.period == 2
      assert loop_info.count == 2
      assert AgentLoop.duplicate_tool_calls?(messages, candidate_call) == true

      desc = AgentLoop.format_cycle_description(loop_info.cycle)
      assert desc =~ "bash(command:"
      assert desc =~ "wc -l"
      assert desc =~ "SOUNDNESS.md"
    end

    test "detects period 3 tool cycle (A -> B -> C -> A -> B -> C)" do
      make_step = fn id, name, arg ->
        %{
          "role" => "assistant",
          "tool_calls" => [
            %{
              "id" => id,
              "function" => %{"name" => name, "arguments" => Yoke.Json.encode!(%{path: arg})}
            }
          ]
        }
      end

      step_a = make_step.("c1", "read_file", "a.txt")
      step_b = make_step.("c2", "read_file", "b.txt")
      step_c = make_step.("c3", "read_file", "c.txt")

      messages = [
        %{"role" => "user", "content" => "Inspect files"},
        step_a,
        %{"role" => "tool", "content" => "a"},
        step_b,
        %{"role" => "tool", "content" => "b"},
        step_c,
        %{"role" => "tool", "content" => "c"},
        step_a,
        %{"role" => "tool", "content" => "a"},
        step_b,
        %{"role" => "tool", "content" => "b"}
      ]

      candidate_c = [%{id: "c6", name: "read_file", arguments: %{"path" => "c.txt"}}]

      assert {:loop, loop_info} = AgentLoop.detect_tool_loop(messages, candidate_c)
      assert loop_info.period == 3
      assert loop_info.count == 2
      assert AgentLoop.duplicate_tool_calls?(messages, candidate_c) == true
    end

    test "detects period 1 loop for job_status polling after 2 identical calls" do
      poll_call = %{
        "role" => "assistant",
        "tool_calls" => [
          %{
            "id" => "call_1",
            "function" => %{
              "name" => "job_status",
              "arguments" => "{\"job_id\":\"job_1\",\"tail\":30}"
            }
          }
        ]
      }

      messages = [
        %{"role" => "user", "content" => "Run the tests"},
        poll_call,
        %{"role" => "tool", "content" => "running"}
      ]

      new_tool_calls = [
        %{id: "call_2", name: "job_status", arguments: %{"job_id" => "job_1", "tail" => 30}}
      ]

      # `job_status` is a terminal probe, not a live one: waiting on the same
      # job twice in a row is already a loop (the job notifies on completion).
      assert {:loop, loop_info} = AgentLoop.detect_tool_loop(messages, new_tool_calls)
      assert loop_info.period == 1
      assert loop_info.count == 2
      assert loop_info.waiting? == true
      assert AgentLoop.duplicate_tool_calls?(messages, new_tool_calls) == true
    end

    test "job_status is not in the repeatable tool list" do
      refute "job_status" in AgentLoop.repeatable_tools()
      assert "job_status" in AgentLoop.non_cycling_tools()
      assert "bash" in AgentLoop.repeatable_tools()
    end

    test "flags a mixed bash/job_status period 2 cycle as a waiting loop" do
      compile = %{
        "role" => "assistant",
        "tool_calls" => [
          %{
            "id" => "c1",
            "function" => %{"name" => "bash", "arguments" => "{\"command\":\"mix test\"}"}
          }
        ]
      }

      poll = %{
        "role" => "assistant",
        "tool_calls" => [
          %{
            "id" => "c2",
            "function" => %{
              "name" => "job_status",
              "arguments" => "{\"job_id\":\"job_1\"}"
            }
          }
        ]
      }

      messages = [
        %{"role" => "user", "content" => "Run the tests"},
        compile,
        %{"role" => "tool", "content" => "job_1"},
        poll,
        %{"role" => "tool", "content" => "running"},
        compile,
        %{"role" => "tool", "content" => "job_2"}
      ]

      candidate = [%{id: "c4", name: "job_status", arguments: %{"job_id" => "job_1"}}]

      assert {:loop, loop_info} = AgentLoop.detect_tool_loop(messages, candidate)
      assert loop_info.period == 2
      assert loop_info.waiting? == true
    end

    test "does not flag a productive bash cycle as waiting" do
      make_step = fn id, cmd ->
        %{
          "role" => "assistant",
          "tool_calls" => [
            %{
              "id" => id,
              "function" => %{"name" => "bash", "arguments" => Yoke.Json.encode!(%{command: cmd})}
            }
          ]
        }
      end

      messages = [
        %{"role" => "user", "content" => "Check"},
        make_step.("c1", "wc -l log"),
        %{"role" => "tool", "content" => "10"},
        make_step.("c2", "tail log"),
        %{"role" => "tool", "content" => "ok"},
        make_step.("c3", "wc -l log"),
        %{"role" => "tool", "content" => "10"}
      ]

      candidate = [%{id: "c4", name: "bash", arguments: %{command: "tail log"}}]

      assert {:loop, loop_info} = AgentLoop.detect_tool_loop(messages, candidate)
      assert loop_info.waiting? == false
    end

    test "does not flag alternating commands when arguments vary" do
      step_a1 = %{
        "role" => "assistant",
        "tool_calls" => [
          %{
            "id" => "c1",
            "function" => %{"name" => "bash", "arguments" => "{\"command\":\"test 1\"}"}
          }
        ]
      }

      step_b1 = %{
        "role" => "assistant",
        "tool_calls" => [
          %{
            "id" => "c2",
            "function" => %{"name" => "bash", "arguments" => "{\"command\":\"test 2\"}"}
          }
        ]
      }

      step_a2 = %{
        "role" => "assistant",
        "tool_calls" => [
          %{
            "id" => "c3",
            "function" => %{"name" => "bash", "arguments" => "{\"command\":\"test 3\"}"}
          }
        ]
      }

      messages = [
        %{"role" => "user", "content" => "Run test series"},
        step_a1,
        %{"role" => "tool", "content" => "ok 1"},
        step_b1,
        %{"role" => "tool", "content" => "ok 2"},
        step_a2,
        %{"role" => "tool", "content" => "ok 3"}
      ]

      candidate = [%{id: "c4", name: "bash", arguments: %{"command" => "test 4"}}]

      assert AgentLoop.detect_tool_loop(messages, candidate) == :ok
      assert AgentLoop.duplicate_tool_calls?(messages, candidate) == false
    end
  end

  test "retains loop protection within a turn, but not across new user requests" do
    call = %{id: "new", name: "custom_analysis", arguments: %{"path" => "lib/a.ex"}}

    old_call = %{
      "role" => "assistant",
      "tool_calls" => [
        %{"function" => %{"name" => call.name, "arguments" => Yoke.Json.encode!(call.arguments)}}
      ]
    }

    history = [
      %{"role" => "user", "content" => "Review A"},
      old_call,
      %{"role" => "tool", "content" => "Old evidence"}
    ]

    assert AgentLoop.duplicate_tool_calls?(history, [call])

    refute AgentLoop.duplicate_tool_calls?(
             history ++
               [
                 %{"role" => "assistant", "content" => "Review A completed"},
                 %{"role" => "user", "content" => "Review B"}
               ],
             [call]
           )
  end

  describe "AgentLoop circuit breaker for non-standard tool failures" do
    test "disables non-standard tool after 3 consecutive failures" do
      state = %{
        tools: [%{name: "mcp_custom_tool"}, %{name: "read_file"}],
        tool_failure_counts: %{},
        messages: []
      }

      {state1, nil} = AgentLoop.handle_tool_failure("mcp_custom_tool", {:error, "failed"}, state)
      assert state1.tool_failure_counts["mcp_custom_tool"] == 1
      assert length(state1.tools) == 2

      {state2, nil} =
        AgentLoop.handle_tool_failure("mcp_custom_tool", {:error, "failed"}, state1)

      assert state2.tool_failure_counts["mcp_custom_tool"] == 2

      {state3, notice} =
        AgentLoop.handle_tool_failure("mcp_custom_tool", {:error, "failed"}, state2)

      assert state3.tool_failure_counts["mcp_custom_tool"] == 3
      assert length(state3.tools) == 1
      assert notice["content"] =~ "Fallback mode activated"
    end

    test "does not count standard tools for failure circuit breaker" do
      state = %{
        tools: [%{name: "read_file"}, %{name: "grep_search"}, %{name: "mcp_ragex_grep"}],
        tool_failure_counts: %{},
        messages: []
      }

      {state1, nil} = AgentLoop.handle_tool_failure("read_file", {:error, "failed"}, state)
      assert state1.tool_failure_counts == %{}

      {state2, nil} = AgentLoop.handle_tool_failure("grep_search", {:error, "failed"}, state1)
      assert state2.tool_failure_counts == %{}

      {state3, nil} =
        AgentLoop.handle_tool_failure("mcp_ragex_grep", {:error, "failed"}, state2)

      assert state3.tool_failure_counts == %{}
    end
  end
end
