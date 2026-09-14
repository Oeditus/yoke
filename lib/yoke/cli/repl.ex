defmodule Yoke.CLI.Repl do
  @moduledoc """
  Interactive REPL loop and slash-command handler for Yoke.
  Includes resilience against actor crashes, slash command validation, and Marcli rendering.
  """
  alias Yoke.Brain.Session
  alias Yoke.Brain.SessionSupervisor
  alias Yoke.CLI.Editor
  alias Yoke.CLI.Formatter
  alias Yoke.Client.DeepSeekAPI
  alias Yoke.Distribution.NodeManager
  alias Yoke.Git
  alias Yoke.MCP.ServerManager, as: MCPServerManager
  alias Yoke.Plugin.Loader, as: PluginLoader
  alias Yoke.Skill.Manager, as: SkillManager

  alias Yoke.CLI.LineEditor

  def start(opts \\ []) do
    MCPServerManager.await_ragex()
    IO.puts(Formatter.banner())

    Yoke.Practices.ensure_practices_for_workspace(".", opts)

    session_id =
      opts[:conversation] || opts[:resume] || opts[:session_id] ||
        Yoke.CLI.Main.generate_uuid()

    session_opts = [
      session_id: session_id,
      model: opts[:model] || "deepseek-chat"
    ]

    session_opts =
      if opts[:endpoint] do
        Keyword.put(session_opts, :endpoint, opts[:endpoint])
      else
        session_opts
      end

    {:ok, session_pid} = SessionSupervisor.start_session(session_opts)

    IO.puts(Formatter.format_info("Brain actor initialized for session '#{session_id}'"))
    IO.puts(Formatter.format_success(Yoke.report_serving_processes()))

    IO.puts(
      Formatter.format_info(
        "Type /help for command menu, !command for direct shell execution, or !! for pure console mode."
      )
    )

    IO.puts(
      Formatter.format_info(
        "Hotkeys: Ctrl+P permissions • Ctrl+G sandbox • Ctrl+B status bar • Ctrl+J newline • Ctrl+Q interrupt turn\n"
      )
    )

    history = LineEditor.load_history()
    loop(session_pid, session_id, history)
  end

  def loop(session_pid, session_id, history \\ [], console_mode? \\ false)

  # "Pure console" mode: entered/exited via the `!!` flip-flop command.
  # While active, Yoke steps completely out of the way -- no Brain/Hands
  # actor calls, no LLM turns, no slash-command dispatch -- and behaves
  # like a bare shell wrapper for quick terminal work, so the user never
  # has to spawn a separate terminal tab just to run a couple of plain
  # commands. Typing `!!` again flips back to the normal harness REPL.
  def loop(session_pid, session_id, history, true) do
    console_loop(session_pid, session_id, history)
  end

  def loop(session_pid, session_id, history, false) do
    # Ensure session actor process is alive before turn
    session_pid = ensure_session_alive(session_pid, session_id)

    # A single get_stats/1 call covers everything the prompt and the idle
    # status bar need (model, hands mode, permission mode, sandbox state,
    # tool/MCP counts, cumulative tokens & cost) -- avoids extra round trips
    # to the session actor per input line.
    stats = Session.get_stats(session_pid)

    prompt_str =
      LineEditor.build_prompt(
        session_id,
        stats.model,
        stats.hands_mode,
        ".",
        stats.sandbox_workspace
      )

    compact_status_bar? =
      Map.get(Yoke.Config.load_config(), "compact_status_bar", false)

    render_context =
      stats
      |> Map.put(:session_pid, session_pid)
      |> Map.put(:last_turn_tokens, latest_turn_delta(session_pid))
      |> Map.put(:git_dirty?, Git.dirty?())
      |> Map.put(:compact_status_bar?, compact_status_bar?)

    case LineEditor.get_line(prompt_str, history, render_context) do
      :eof ->
        graceful_shutdown()
        print_resume_banner(session_id)

      {:error, reason} ->
        IO.puts(Formatter.format_error("Input error: #{inspect(reason)}"))

      line when is_binary(line) ->
        trimmed = String.trim(line)
        updated_history = if trimmed != "", do: [trimmed | history], else: history

        case handle_input(trimmed, session_pid, session_id) do
          :continue ->
            loop(session_pid, session_id, updated_history, false)

          :toggle_console ->
            IO.puts(
              Formatter.format_success(
                "Flipped into pure console mode -- plain shell passthrough, no AI/tooling in between. Type !! again to return to Yoke."
              )
            )

            loop(session_pid, session_id, updated_history, true)

          {:switch_session, new_id, new_pid} ->
            loop(new_pid, new_id, updated_history, false)

          :exit ->
            graceful_shutdown()
            print_resume_banner(session_id)
            :ok
        end
    end
  end

  # Stops any externally spawned processes (e.g. the per-project Ragex/dllb
  # instance) before the VM halts. `System.halt/1` (called by the escript
  # runtime once `main/1` returns) skips normal port cleanup, so without
  # this the per-project `dllb-server` OS process is left running as an
  # orphan, and the next launch can't reliably reuse its on-disk cache --
  # forcing a full re-index every time instead of an instant cache hit.
  defp graceful_shutdown do
    MCPServerManager.stop_ragex()
  catch
    _, _ -> :ok
  end

  def handle_input("", _session_pid, _session_id), do: :continue
  def handle_input("/exit", _pid, _id), do: :exit
  def handle_input("/quit", _pid, _id), do: :exit

  # Flip-flop into/out of "pure console" mode. Must be matched before the
  # generic `"!" <> cmd` shell shortcut below, since that clause would
  # otherwise swallow "!!" as the shell command "!".
  def handle_input("!!", _session_pid, _session_id), do: :toggle_console

  # Shell execution shortcut: !command
  def handle_input("!" <> cmd, _session_pid, _session_id) do
    cmd = String.trim(cmd)
    IO.puts(Formatter.format_info("Executing shell command: #{cmd}"))

    case System.cmd("sh", ["-c", cmd], stderr_to_stdout: true) do
      {out, 0} -> IO.puts("\n#{out}\n")
      {out, code} -> IO.puts(Formatter.format_error("Exit status #{code}:\n#{out}"))
    end

    :continue
  end

  def handle_input("/help", _session_pid, _session_id) do
    IO.puts(Formatter.help_menu())
    :continue
  end

  def handle_input("/doctor", _session_pid, _session_id) do
    Yoke.CLI.Doctor.print_report()
    :continue
  end

  def handle_input("/guide", _session_pid, _session_id) do
    IO.puts(Formatter.getting_started_guide())
    :continue
  end

  def handle_input("/docs", _session_pid, _session_id) do
    IO.puts(Formatter.getting_started_guide())
    :continue
  end

  def handle_input("/getting-started", _session_pid, _session_id) do
    IO.puts(Formatter.getting_started_guide())
    :continue
  end

  def handle_input("/clear", _session_pid, _session_id) do
    IO.write("\e[H\e[2J")
    :continue
  end

  def handle_input("/reset", session_pid, _session_id) do
    case Session.reset(session_pid) do
      :ok ->
        IO.write("\e[H\e[2J")

        IO.puts(
          Formatter.format_success(
            "Session reset! Conversation history, context tokens, checkpoints, and screen cleared."
          )
        )

      {:error, err} ->
        IO.puts(Formatter.format_error(err))
    end

    :continue
  end

  def handle_input("/compact", session_pid, _session_id) do
    IO.puts(Formatter.format_info("Compressing conversation context…"))

    case Session.compact_context(session_pid) do
      {:ok, summary} ->
        IO.puts(Formatter.format_success("Context successfully compressed!"))
        md = "### Compressed Context Summary\n" <> summary
        IO.puts("\n" <> Formatter.format_markdown(md) <> "\n")

      {:error, err} ->
        IO.puts(Formatter.format_error(err))
    end

    :continue
  end

  def handle_input("/diff " <> target, _session_pid, _session_id) do
    t = String.trim(target)

    case Git.diff(t) do
      {:ok, diff_out} ->
        IO.puts("\n#{Formatter.bold()}Git Diff (#{t}):#{Formatter.reset()}\n#{diff_out}\n")

      {:error, err} ->
        IO.puts(Formatter.format_error(err))
    end

    :continue
  end

  def handle_input("/diff", _session_pid, _session_id) do
    case Git.diff() do
      {:ok, diff_out} ->
        IO.puts("\n#{Formatter.bold()}Workspace Git Diff:#{Formatter.reset()}\n#{diff_out}\n")

      {:error, err} ->
        IO.puts(Formatter.format_error(err))
    end

    :continue
  end

  def handle_input("/cr " <> base, session_pid, session_id) do
    b = String.trim(base)
    b = if b == "", do: "main", else: b
    handle_input("/review #{b} HEAD", session_pid, session_id)
  end

  def handle_input("/cr", session_pid, session_id) do
    handle_input("/review main HEAD", session_pid, session_id)
  end

  def handle_input("/git " <> args, _session_pid, _session_id) do
    args = String.trim(args)

    case Git.run(args) do
      {:ok, out} ->
        IO.puts("\n#{Formatter.bold()}$ git #{args}#{Formatter.reset()}\n#{out}\n")

      {:error, err} ->
        IO.puts(Formatter.format_error(err))
    end

    :continue
  end

  def handle_input("/git", _session_pid, _session_id) do
    IO.puts(
      Formatter.format_info(
        "Usage: /git <subcommand> [args...]  (e.g. /git status, /git log --oneline -5, /git branch -a)"
      )
    )

    :continue
  end

  def handle_input("/sweep " <> args, _session_pid, _session_id) do
    tokens = String.trim(args)

    if tokens == "" do
      IO.puts(
        Formatter.format_info("Usage: /sweep <token1> [token2...] (e.g. /sweep auth jwt session)")
      )
    else
      result = Yoke.Sweep.run(tokens)
      IO.puts("\n" <> Yoke.Sweep.format_result(result) <> "\n")
    end

    :continue
  end

  def handle_input("/sweep", _session_pid, _session_id) do
    IO.puts(
      Formatter.format_info("Usage: /sweep <token1> [token2...] (e.g. /sweep auth jwt session)")
    )

    :continue
  end

  def handle_input("/scrap clear", _session_pid, _session_id) do
    Yoke.Scrap.clear_scrap()
    IO.puts(Formatter.format_success("Scrap notes cleared!"))
    :continue
  end

  def handle_input("/scrap add " <> note, _session_pid, _session_id) do
    {:ok, path} = Yoke.Scrap.append_note(note)
    IO.puts(Formatter.format_success("Scrap note saved to #{path}!"))
    :continue
  end

  def handle_input("/scrap " <> note, session_pid, session_id) do
    n = String.trim(note)

    if n == "" do
      handle_input("/scrap", session_pid, session_id)
    else
      {:ok, path} = Yoke.Scrap.append_note(n)
      IO.puts(Formatter.format_success("Scrap note saved to #{path}!"))
      :continue
    end
  end

  def handle_input("/scrap", _session_pid, _session_id) do
    {:ok, content, path} = Yoke.Scrap.read_scrap()
    IO.puts("\n" <> Yoke.Scrap.format_scrap(content, path) <> "\n")
    :continue
  end

  def handle_input("/lessons add " <> lesson, _session_pid, _session_id) do
    {:ok, path} = Yoke.Lessons.append_lesson(lesson)
    IO.puts(Formatter.format_success("Lesson saved to #{path}!"))
    :continue
  end

  def handle_input("/lessons " <> lesson, session_pid, session_id) do
    l = String.trim(lesson)

    if l == "" do
      handle_input("/lessons", session_pid, session_id)
    else
      {:ok, path} = Yoke.Lessons.append_lesson(l)
      IO.puts(Formatter.format_success("Lesson saved to #{path}!"))
      :continue
    end
  end

  def handle_input("/lessons", _session_pid, _session_id) do
    {:ok, content, path} = Yoke.Lessons.load_lessons()
    IO.puts("\n" <> Yoke.Lessons.format_lessons(content, path) <> "\n")
    :continue
  end

  def handle_input("/thought " <> input, _session_pid, _session_id) do
    {title, summary} =
      case String.split(input, "|", parts: 2) do
        [t, s] -> {String.trim(t), String.trim(s)}
        [t] -> {String.trim(t), "Raw thought captured via /thought command."}
      end

    {:ok, path, slug} = Yoke.WorkflowIndex.create_thought(title, summary)
    IO.puts(Formatter.format_success("Thought created: `#{slug}` -> #{path}"))

    :continue
  end

  def handle_input("/thought", _session_pid, _session_id) do
    IO.puts(
      Formatter.format_info(
        "Usage: /thought <Title> [| Summary] (e.g. /thought JWT Refresh Token | Implement auto-refresh token flow)"
      )
    )

    :continue
  end

  def handle_input("/backlog", _session_pid, _session_id) do
    items = Yoke.WorkflowIndex.scan_items()

    if Enum.empty?(items) do
      IO.puts(
        Formatter.format_info(
          "No pipeline items found. Create your first thought with `/thought <Title>`."
        )
      )
    else
      {:ok, map_path, _deps_path} = Yoke.WorkflowIndex.generate_indexes()
      content = File.read!(map_path)

      IO.puts(
        "\n#{Formatter.bold()}=== Idea Pipeline Map (#{map_path}) ===#{Formatter.reset()}\n\n" <>
          content
      )
    end

    :continue
  end

  def handle_input("/promote " <> args, _session_pid, _session_id) do
    parts = String.split(args, ~r/\s+/, trim: true)

    case parts do
      [slug | rest] ->
        type = Enum.find(rest, &(&1 in ["code", "initiative"])) || "code"
        priority = Enum.reject(rest, &(&1 in ["code", "initiative"])) |> Enum.join(" ")
        priority = if priority == "", do: "Should Have", else: priority

        case Yoke.WorkflowIndex.promote_item(slug, "backlog",
               type: type,
               priority: priority
             ) do
          {:ok, path} ->
            IO.puts(
              Formatter.format_success("Promoted `#{slug}` to backlog (#{priority}) -> #{path}")
            )

          {:error, err} ->
            IO.puts(Formatter.format_error(err))
        end

      _ ->
        IO.puts(
          Formatter.format_info(
            "Usage: /promote <slug> [code|initiative] [Must Have|Should Have|Nice to Have]"
          )
        )
    end

    :continue
  end

  def handle_input("/promote", _session_pid, _session_id) do
    IO.puts(
      Formatter.format_info(
        "Usage: /promote <slug> [code|initiative] [Must Have|Should Have|Nice to Have]"
      )
    )

    :continue
  end

  def handle_input("/what-next", _session_pid, _session_id) do
    items = Yoke.WorkflowIndex.scan_items()
    backlog = Enum.filter(items, &(&1.stage == "backlog"))
    thoughts = Enum.filter(items, &(&1.stage == "thoughts"))

    msg =
      cond do
        not Enum.empty?(backlog) ->
          must_haves = Enum.filter(backlog, &(Map.get(&1.frontmatter, "priority") == "Must Have"))
          top = if Enum.empty?(must_haves), do: hd(backlog), else: hd(must_haves)

          "Top recommendation to work on next: `#{top.slug}` (#{Map.get(top.frontmatter, "priority", "backlog")})\nFile: #{top.path}"

        not Enum.empty?(thoughts) ->
          top = hd(thoughts)
          "No backlog items found. Ready to refine thought `#{top.slug}`?\nFile: #{top.path}"

        true ->
          "No items in backlog or thoughts. Capture a new idea with `/thought <Title>`!"
      end

    IO.puts("\n" <> Formatter.format_info(msg) <> "\n")
    :continue
  end

  def handle_input("/audit-thoughts", _session_pid, _session_id) do
    case Yoke.WorkflowIndex.check_items() do
      {:ok, items} ->
        IO.puts(
          Formatter.format_success(
            "Audit passed! All #{length(items)} pipeline items have valid frontmatter & dependencies."
          )
        )

      {:error, errs} ->
        err_text = Enum.map_join(errs, "\n", &"  - #{&1}")
        IO.puts(Formatter.format_error("Audit found integrity issues:\n" <> err_text))
    end

    :continue
  end

  def handle_input("/process-scrap", _session_pid, _session_id) do
    case Yoke.Scrap.read_scrap() do
      {:ok, content, path} ->
        IO.puts(
          Formatter.format_info(
            "Scrap Triage (#{path}):\n" <>
              content <>
              "\n\nUse `/thought <Title> | <Summary>` to turn scrap items into raw thoughts, or `/scrap clear` when done."
          )
        )

      {:error, err} ->
        IO.puts(Formatter.format_error(err))
    end

    :continue
  end

  def handle_input("/prune-lessons", _session_pid, _session_id) do
    case Yoke.Lessons.load_lessons() do
      {:ok, content, path} ->
        IO.puts(
          Formatter.format_info(
            "Lessons Triage (#{path}):\n\n" <>
              content <>
              "\n\nSynthesize clusters of lessons into project/reference/ docs or module docstrings."
          )
        )

      {:error, err} ->
        IO.puts(Formatter.format_error(err))
    end

    :continue
  end

  def handle_input("/prune-completed", _session_pid, _session_id) do
    items = Yoke.WorkflowIndex.scan_items()
    completed = Enum.filter(items, &(&1.stage == "completed"))

    if Enum.empty?(completed) do
      IO.puts(Formatter.format_info("No completed items in project/workflow/completed/."))
    else
      list = Enum.map_join(completed, "\n", &"  - #{&1.slug} (#{&1.path})")

      checklist = """
      === Prune Completed Checklist ===
      1. Verify test coverage exists for each completed item.
      2. Extract rationale into module docstrings or inline comments.
      3. Move cross-cutting gotchas into project/lessons.md.
      4. Move durable topical knowledge into project/reference/.

      Completed items ready for pruning check:
      #{list}
      """

      IO.puts(Formatter.format_info(checklist))
    end

    :continue
  end

  def handle_input("/spar adversarial " <> topic, session_pid, _session_id) do
    t = String.trim(topic)
    {:ok, sweep_fmt, prompt} = Yoke.Sparring.prepare_sparring(t, mode: :adversarial)

    IO.puts("\n" <> Yoke.Sparring.format_spar_start(t, :adversarial, sweep_fmt) <> "\n")

    case Session.send_user_message(session_pid, prompt) do
      {:ok, response} ->
        IO.puts(Formatter.format_agent_response(response.content))

      {:error, err} ->
        IO.puts(Formatter.format_error(err))
    end

    :continue
  end

  def handle_input("/spar socratic " <> topic, session_pid, _session_id) do
    t = String.trim(topic)
    {:ok, sweep_fmt, prompt} = Yoke.Sparring.prepare_sparring(t, mode: :socratic)
    IO.puts("\n" <> Yoke.Sparring.format_spar_start(t, :socratic, sweep_fmt) <> "\n")

    case Session.send_user_message(session_pid, prompt) do
      {:ok, response} ->
        IO.puts(Formatter.format_agent_response(response.content))

      {:error, err} ->
        IO.puts(Formatter.format_error(err))
    end

    :continue
  end

  def handle_input("/spar " <> topic, session_pid, session_id) do
    t = String.trim(topic)

    if String.starts_with?(t, "adversarial") or String.starts_with?(t, "socratic") do
      handle_input("/spar " <> t, session_pid, session_id)
    else
      {:ok, sweep_fmt, prompt} = Yoke.Sparring.prepare_sparring(t, mode: :socratic)
      IO.puts("\n" <> Yoke.Sparring.format_spar_start(t, :socratic, sweep_fmt) <> "\n")

      case Session.send_user_message(session_pid, prompt) do
        {:ok, response} ->
          IO.puts(Formatter.format_agent_response(response.content))

        {:error, err} ->
          IO.puts(Formatter.format_error(err))
      end

      :continue
    end
  end

  def handle_input("/spar", _session_pid, _session_id) do
    IO.puts(
      Formatter.format_info(
        "Usage: /spar [socratic|adversarial] <topic | slug> (e.g. /spar JWT Refresh Token)"
      )
    )

    :continue
  end

  def handle_input("/linter " <> args, _session_pid, _session_id) do
    args = String.trim(args)

    IO.puts(Formatter.format_info("Running linter tool: #{args}…"))

    case Yoke.Linter.run(args) do
      {:ok, out} ->
        IO.puts("\n#{out}\n")

      {:error, err} ->
        IO.puts(Formatter.format_error(err))
    end

    :continue
  end

  def handle_input("/linter", _session_pid, _session_id) do
    IO.puts(Yoke.Linter.help_text())
    :continue
  end

  def handle_input("/lint " <> args, session_pid, session_id) do
    handle_input("/linter " <> args, session_pid, session_id)
  end

  def handle_input("/lint", session_pid, session_id) do
    handle_input("/linter", session_pid, session_id)
  end

  def handle_input("/review conversation " <> target, session_pid, session_id) do
    handle_review_conversation(target, session_pid, session_id)
  end

  def handle_input("/review conversation", session_pid, session_id) do
    handle_review_conversation(nil, session_pid, session_id)
  end

  def handle_input("/review_conversation " <> target, session_pid, session_id) do
    handle_review_conversation(target, session_pid, session_id)
  end

  def handle_input("/review_conversation", session_pid, session_id) do
    handle_review_conversation(nil, session_pid, session_id)
  end

  def handle_input("/review-conversation " <> target, session_pid, session_id) do
    handle_review_conversation(target, session_pid, session_id)
  end

  def handle_input("/review-conversation", session_pid, session_id) do
    handle_review_conversation(nil, session_pid, session_id)
  end

  def handle_input("/conversation " <> target, session_pid, session_id) do
    target = String.trim(target)

    if String.starts_with?(target, "review") do
      id = target |> String.replace_prefix("review", "") |> String.trim()
      handle_review_conversation(id, session_pid, session_id)
    else
      handle_review_conversation(target, session_pid, session_id)
    end
  end

  def handle_input("/conversation", session_pid, session_id) do
    handle_review_conversation(nil, session_pid, session_id)
  end

  def handle_input("/review " <> args, session_pid, _session_id) do
    parts = String.split(args, " ", trim: true)

    {base_branch, head_branch} =
      case parts do
        [pr_num] ->
          if Regex.match?(~r/^\d+$/, pr_num) do
            case Yoke.PRReview.detect_pr(pr_num) do
              {:ok, info} ->
                {info.base || "main", info.head || "HEAD"}

              _ ->
                {"main", "HEAD"}
            end
          else
            {pr_num, "HEAD"}
          end

        [base, head | _] ->
          {base, head}

        _ ->
          {"main", "HEAD"}
      end

    IO.puts(
      Formatter.format_info(
        "Comparing branches '#{base_branch}' vs '#{head_branch}' and generating Code Review…"
      )
    )

    review_fn = fn -> Session.generate_code_review(session_pid, base_branch, head_branch) end

    res =
      Yoke.CLI.Spinner.run(
        fn -> Yoke.CLI.Interrupt.run(session_pid, review_fn) end,
        title: "Generating Code Review… (Ctrl+Q to interrupt)"
      )

    case res do
      {:ok, %{content: review_md}} ->
        IO.puts("\n" <> Formatter.format_agent_response(review_md) <> "\n")
        Formatter.flush()

        findings = Yoke.PRReview.parse_findings(review_md)

        if findings == [] do
          IO.puts(Formatter.format_info("No discrete actionable findings parsed from review."))
        else
          {:ok, accepted_findings, _declined} = Yoke.PRReview.interactive_review(findings)

          if accepted_findings != [] do
            fix_prompt = Yoke.PRReview.build_fix_prompt(accepted_findings)
            pr_body = Yoke.PRReview.build_pr_comment_body(accepted_findings, fix_prompt)

            post_question = "Post accepted findings to GitHub PR?"

            post_options = [
              "Yes, post findings to GitHub PR (Recommended)",
              "No, skip posting to GitHub"
            ]

            post_choice = Yoke.CLI.QuestionPrompt.ask_single_question(post_question, post_options)

            selected_post =
              case post_choice do
                %{selected: [c | _]} -> c
                %{custom: c} when is_binary(c) -> c
                _ -> "Yes"
              end

            if String.starts_with?(selected_post, "Yes") or String.contains?(selected_post, "Yes") do
              case Yoke.PRReview.post_to_github_pr(head_branch, pr_body) do
                {:ok, pr_info} ->
                  IO.puts(
                    Formatter.format_success(
                      "Successfully posted review findings to GitHub PR ##{pr_info.number} (#{pr_info.url})"
                    )
                  )

                {:error, err} ->
                  IO.puts(Formatter.format_warning("Could not post to GitHub PR: #{err}"))
              end
            end

            IO.puts(
              "\n" <> Formatter.cyan() <> "🛠️ Yoke Code Review Fix Prompt:" <> Formatter.reset()
            )

            IO.puts(Formatter.dim() <> fix_prompt <> Formatter.reset() <> "\n")
            Formatter.flush()

            apply_question = "Would you like Yoke to examine and apply these fixes now?"

            apply_options = [
              "Yes, apply fixes now (Recommended)",
              "No, I will apply them later"
            ]

            apply_choice =
              Yoke.CLI.QuestionPrompt.ask_single_question(apply_question, apply_options)

            selected_apply =
              case apply_choice do
                %{selected: [c | _]} -> c
                %{custom: c} when is_binary(c) -> c
                _ -> "Yes"
              end

            if String.starts_with?(selected_apply, "Yes") or
                 String.contains?(selected_apply, "Yes") do
              IO.puts(Formatter.format_info("Passing fix prompt to Yoke model…"))

              apply_fn = fn -> Session.send_user_message(session_pid, fix_prompt) end

              fix_res =
                Yoke.CLI.Spinner.run(
                  fn -> Yoke.CLI.Interrupt.run(session_pid, apply_fn) end,
                  title: "Applying Code Review fixes… (Ctrl+Q to interrupt)"
                )

              case fix_res do
                {:ok, %{content: fix_reply}} ->
                  IO.puts("\n" <> Formatter.format_agent_response(fix_reply) <> "\n")
                  Formatter.flush()

                {:error, err} ->
                  IO.puts(Formatter.format_error(err))
                  Formatter.flush()
              end
            end
          else
            IO.puts(Formatter.format_info("No findings were accepted by user."))
          end
        end

      {:error, err} ->
        IO.puts(Formatter.format_error(err))
        Formatter.flush()
    end

    :continue
  end

  def handle_input("/review", session_pid, session_id) do
    handle_input("/review main HEAD", session_pid, session_id)
  end

  def handle_input("/commit " <> msg, _session_pid, _session_id) do
    msg = String.trim(msg)

    case Git.commit(msg) do
      {:ok, out} ->
        IO.puts(Formatter.format_success("Git commit created:\n#{out}"))

      {:error, err} ->
        IO.puts(Formatter.format_error(err))
    end

    :continue
  end

  def handle_input("/import " <> args, _session_pid, _session_id) do
    case String.split(String.trim(args), ~r/\s+/, trim: true) do
      [path] ->
        handle_import_session(path, nil)

      [path, session_id | _] ->
        handle_import_session(path, session_id)

      [] ->
        IO.puts(
          Formatter.format_error("Usage: /import <path/to/session.lmml|.json> [session_id]")
        )
    end

    :continue
  end

  def handle_input("/import", _session_pid, _session_id) do
    IO.puts(Formatter.format_error("Usage: /import <path/to/session.lmml|.json> [session_id]"))
    :continue
  end

  def handle_input("/cb", session_pid, session_id),
    do: handle_copy_clipboard(session_pid, session_id)

  def handle_input("/clipboard image", session_pid, session_id),
    do: handle_paste_clipboard_image(session_pid, session_id)

  def handle_input("/clipboard paste", session_pid, session_id),
    do: handle_paste_clipboard_image(session_pid, session_id)

  def handle_input("/clipboard", session_pid, session_id),
    do: handle_copy_clipboard(session_pid, session_id)

  def handle_input("/paste image", session_pid, session_id),
    do: handle_paste_clipboard_image(session_pid, session_id)

  def handle_input("/paste", session_pid, session_id),
    do: handle_paste_clipboard_image(session_pid, session_id)

  def handle_input("/cost", session_pid, _session_id) do
    stats = Session.get_token_stats(session_pid)
    prompt_tokens = stats[:tracked_prompt_tokens] || stats[:estimated_prompt_tokens] || 0

    md = """
    ### Session Token & Cost Statistics
    - **Estimated Context Tokens**: `#{prompt_tokens}`
    - **Completion Tokens**: `#{stats.tracked_completion_tokens}`
    - **Total Session Tokens**: `#{stats.total_tokens}`
    - **Estimated Cost (USD)**: `$#{:erlang.float_to_binary(stats.estimated_cost_usd, [{:decimals, 6}])}`
    """

    IO.puts("\n" <> Formatter.format_markdown(md) <> "\n")
    :continue
  end

  def handle_input("/stats", session_pid, _session_id) do
    stats = Session.get_stats(session_pid)

    md = """
    ### Session Analytics & Statistics Dashboard
    - **Session ID**: `#{stats.session_id}`
    - **Model**: `#{stats.model}`
    - **Permission Safety**: `#{stats.permission_mode}`
    - **Sandbox Bounds**: `#{if stats.sandbox_workspace, do: "enabled", else: "disabled"}`
    - **Messages Count**: `#{stats.message_count}`
    - **Snapshots**: `#{stats.snapshot_count}`
    - **Execution Mode**: `#{stats.hands_mode}`
    - **Total Prompt Tokens**: `#{stats.tracked_prompt_tokens}`
    - **Total Completion Tokens**: `#{stats.tracked_completion_tokens}`
    - **Total Tokens**: `#{stats.total_tokens}`
    - **Estimated Cost (USD)**: `$#{:erlang.float_to_binary(stats.estimated_cost_usd, [{:decimals, 6}])}`
    - **Registered Tools**: `#{stats.tools_count}`
    - **Connected MCP Servers**: `#{stats.mcp_servers_count}`
    - **Max Tool Iteration Depth**: `#{stats.max_tool_depth}`
    """

    IO.puts("\n" <> Formatter.format_markdown(md) <> "\n")
    :continue
  end

  def handle_input("/tokens", session_pid, _session_id) do
    turns = Session.get_turn_tokens(session_pid)
    stats = Session.get_token_stats(session_pid)

    rows =
      if Enum.empty?(turns) do
        "| Turn #1 | 0 | 0 | 0 |"
      else
        Enum.map_join(turns, "\n", fn t ->
          "| Turn ##{t.turn} | #{t.prompt_tokens} | #{t.completion_tokens} | #{t.total_tokens} |"
        end)
      end

    md = """
    ### Per-Turn Token Breakdown
    | Turn | Prompt Tokens | Completion Tokens | Total Tokens |
    |---|---|---|---|
    #{rows}

    **Session Cumulative Total**: `#{stats.total_tokens}` tokens (`$#{:erlang.float_to_binary(stats.estimated_cost_usd, [{:decimals, 6}])}`)
    """

    IO.puts("\n" <> Formatter.format_markdown(md) <> "\n")
    :continue
  end

  def handle_input("/sandbox " <> mode, session_pid, _session_id) do
    enabled =
      case String.trim(mode) do
        "on" -> true
        "true" -> true
        "enable" -> true
        _ -> false
      end

    {:ok, val} = Session.set_sandbox_mode(session_pid, enabled)

    status_str =
      if val, do: "ENABLED (file refs & tools restricted to workspace)", else: "DISABLED"

    IO.puts(Formatter.format_success("Workspace sandbox bounds set to: #{status_str}"))
    :continue
  end

  def handle_input("/sandbox", session_pid, session_id) do
    handle_input("/sandbox on", session_pid, session_id)
  end

  def handle_input("/export " <> format, session_pid, _session_id) do
    fmt =
      case String.trim(format) do
        "json" -> :json
        "lmml" -> :lmml
        "lmmlz" -> :lmmlz
        _ -> :markdown
      end

    case Session.export_session(session_pid, fmt) do
      {:ok, path} ->
        IO.puts(Formatter.format_success("Session history successfully exported to: #{path}"))

      {:error, err} ->
        IO.puts(Formatter.format_error(err))
    end

    :continue
  end

  def handle_input("/export", session_pid, session_id) do
    handle_input("/export markdown", session_pid, session_id)
  end

  def handle_input("/permissions " <> mode, session_pid, _session_id) do
    perm =
      case String.trim(mode) do
        "auto" -> :auto_approve
        "yolo" -> :auto_approve
        _ -> :ask_confirm
      end

    {:ok, mode_set} = Session.set_permission_mode(session_pid, perm)
    IO.puts(Formatter.format_success("Permission safety mode set to: #{mode_set}"))
    :continue
  end

  # ---------------------------------------------------------------------
  # /skills -- unified skill command surface
  #
  #   /skills                     list discovered skills
  #   /skills <name> [args]       execute a skill (args substituted into body)
  #   /skills show <name>         print the raw SKILL.md body
  #   /skills path <name>         print the resolved SKILL.md path
  #   /skills edit <name>         open the SKILL.md in $EDITOR
  #   /skills new <name>          scaffold a new skill in .yoke/skills
  #   /skills --global <name>     force the global (~/.yoke/skills) source
  #
  # `/skill <name>` is retained as a back-compat alias.
  # ---------------------------------------------------------------------

  def handle_input("/skills", _session_pid, _session_id) do
    print_skills_list(SkillManager.discover_skills())
    :continue
  end

  def handle_input("/skills show " <> name, _session_pid, _session_id) do
    with_skill(name, fn skill ->
      md = "### `#{skill.name}` (#{skill.scope})\n\n#{skill.content}"
      IO.puts("\n" <> Formatter.format_markdown(md) <> "\n")
    end)

    :continue
  end

  def handle_input("/skills path " <> name, _session_pid, _session_id) do
    with_skill(name, fn skill ->
      IO.puts(Formatter.format_info("#{skill.name} → #{skill.path}"))
    end)

    :continue
  end

  def handle_input("/skills edit " <> name, _session_pid, _session_id) do
    with_skill(name, fn skill ->
      Editor.edit_file(skill.path)
    end)

    :continue
  end

  def handle_input("/skills new " <> name, _session_pid, _session_id) do
    name = String.trim(name)
    root = Path.join(File.cwd!(), ".yoke/skills")

    case SkillManager.scaffold(name, root) do
      {:ok, path} ->
        SkillManager.invalidate_cache()
        IO.puts(Formatter.format_success("Scaffolded skill '#{name}' at #{path}"))

      {:error, err} ->
        IO.puts(Formatter.format_error(err))
    end

    :continue
  end

  def handle_input("/skills --global " <> name, session_pid, session_id) do
    execute_skill(String.trim(name), "",
      global: true,
      session_pid: session_pid,
      session_id: session_id
    )

    :continue
  end

  def handle_input("/skills " <> rest, session_pid, session_id) do
    {name, args} = split_skill_invocation(rest)

    if name in ["show", "path", "edit", "new"] do
      IO.puts(Formatter.format_error("Usage: /skills #{name} <skill-name>"))
    else
      execute_skill(name, args, session_pid: session_pid, session_id: session_id)
    end

    :continue
  end

  # Back-compat alias for the singular form.
  def handle_input("/skill " <> rest, session_pid, session_id) do
    {name, args} = split_skill_invocation(rest)
    execute_skill(name, args, session_pid: session_pid, session_id: session_id)
    :continue
  end

  def handle_input("/subagent " <> prompt, session_pid, _session_id) do
    prompt = String.trim(prompt)
    IO.puts(Formatter.format_info("Spawning background subagent for task: \"#{prompt}\"…"))

    case Session.spawn_subagent(session_pid, prompt) do
      {:ok, result} ->
        md = "### Subagent Completed Result\n" <> result
        IO.puts("\n" <> Formatter.format_markdown(md) <> "\n")

      {:error, err} ->
        IO.puts(Formatter.format_error("Subagent failed: #{err}"))
    end

    :continue
  end

  def handle_input("/plugins", _session_pid, _session_id) do
    tools = PluginLoader.list_tools()

    tools_rows =
      Enum.map_join(tools, "\n", fn t -> "- **`#{t.name}`**: #{t.description}" end)

    md = "### Registered Tools (#{length(tools)})\n\n#{tools_rows}"
    IO.puts("\n" <> Formatter.format_markdown(md) <> "\n")
    :continue
  end

  def handle_input("/plugins reload", _session_pid, _session_id) do
    case PluginLoader.reload_all() do
      {:ok, tools_list} ->
        IO.puts(
          Formatter.format_success(
            "Hot-reloaded plugins and updated active Brain actors! Total tools: #{length(tools_list)}"
          )
        )

      {:error, err} ->
        IO.puts(Formatter.format_error("Plugin reload failed: #{err}"))
    end

    :continue
  end

  # Handle all variations of /mcp list, /mcp ls, /mcp
  def handle_input("/mcp list", session_pid, session_id),
    do: handle_mcp_list(session_pid, session_id)

  def handle_input("/mcp ls", session_pid, session_id),
    do: handle_mcp_list(session_pid, session_id)

  def handle_input("/mcp", session_pid, session_id), do: handle_mcp_list(session_pid, session_id)

  def handle_input("/mcp load", _session_pid, _session_id) do
    IO.puts(Formatter.format_info("Loading MCP servers configured in config.json…"))

    case MCPServerManager.load_from_config() do
      {:ok, results} ->
        IO.puts(Formatter.format_success("MCP servers loaded: #{inspect(results)}"))

      {:error, err} ->
        IO.puts(Formatter.format_error(err))
    end

    :continue
  end

  def handle_input("/mcp add " <> args, _session_pid, _session_id) do
    parts = String.split(args, " ", trim: true)

    case parts do
      [name, cmd | cmd_args] ->
        IO.puts(Formatter.format_info("Connecting to MCP server '#{name}' via '#{cmd}'…"))

        case MCPServerManager.add_server(name, cmd, cmd_args) do
          {:ok, tools} ->
            IO.puts(
              Formatter.format_success(
                "Connected MCP server '#{name}'! Registered #{length(tools)} tools."
              )
            )

          {:error, err} ->
            IO.puts(Formatter.format_error(err))
        end

      _ ->
        IO.puts(Formatter.format_error("Usage: /mcp add <name> <command> [args...]"))
    end

    :continue
  end

  def handle_input("/ragex", _session_pid, _session_id) do
    target_dir = File.cwd!()

    IO.puts(
      Formatter.format_info("Mounting Ragex MCP server targeting workspace '#{target_dir}'…")
    )

    case MCPServerManager.start_ragex(target_dir: target_dir) do
      {:ok, dir, tools} ->
        IO.puts(
          Formatter.format_success(
            "Mounted Ragex MCP server targeting '#{dir}'! Registered #{length(tools)} code analysis & refactoring tools."
          )
        )

      {:error, err} ->
        IO.puts(Formatter.format_error(err))
    end

    :continue
  end

  def handle_input("/models", session_pid, session_id) do
    handle_input("/model", session_pid, session_id)
  end

  def handle_input("/model", session_pid, _session_id) do
    {:ok, current_model} = Session.get_model(session_pid)
    {:ok, endpoint} = Session.get_endpoint(session_pid)

    IO.puts(Formatter.format_info("Fetching available models from API endpoint (#{endpoint})…"))

    case DeepSeekAPI.list_models(endpoint: endpoint) do
      {:ok, models} ->
        IO.puts(Formatter.format_success("Available Models from DeepSeek API:"))

        Enum.each(models, fn m ->
          if m == current_model do
            IO.puts("  #{Formatter.green()}● #{m} (active)#{Formatter.reset()}")
          else
            IO.puts("  #{Formatter.cyan()}• #{m}#{Formatter.reset()}")
          end
        end)

        IO.puts(Formatter.format_info("\nUse '/model <model_id>' to switch active model."))

      {:error, err} ->
        IO.puts(Formatter.format_error("Failed to fetch models from API: #{err}"))
        IO.puts(Formatter.format_info("Current active model: '#{current_model}'"))
    end

    :continue
  end

  def handle_input("/model " <> target, session_pid, session_id) do
    clean_target = String.trim(target)

    if clean_target in ["", "list", "ls"] do
      handle_input("/model", session_pid, session_id)
    else
      target_model =
        case clean_target do
          "reasoner" -> "deepseek-reasoner"
          "r1" -> "deepseek-reasoner"
          "chat" -> "deepseek-chat"
          "v3" -> "deepseek-chat"
          "coder" -> "deepseek-coder"
          "v2.5" -> "deepseek-coder"
          "vision" -> "deepseek-v4-flash-vision-exp"
          "v4" -> "deepseek-v4-flash-vision-exp"
          other -> other
        end

      {:ok, current} = Session.set_model(session_pid, target_model)
      IO.puts(Formatter.format_success("Switched model to '#{current}'"))
      :continue
    end
  end

  def handle_input("/edit", session_pid, _session_id) do
    case Editor.edit_text("") do
      {:ok, text} when byte_size(text) > 0 ->
        IO.puts(Formatter.format_info("Sending prompt written via $EDITOR…"))
        Session.send_user_message(session_pid, text)

      {:ok, _} ->
        IO.puts(Formatter.format_info("Prompt edit cancelled (empty text)."))

      {:fallback, _} ->
        IO.puts(
          Formatter.format_error(
            "No $EDITOR or $VISUAL environment variable is set. Please export $EDITOR (e.g. export EDITOR=vim) to compose prompts in editor."
          )
        )

      {:error, err} ->
        IO.puts(Formatter.format_error("Editor error: #{err}"))
    end

    :continue
  end

  def handle_input("/edit " <> target, session_pid, _session_id) do
    path = String.trim(target)

    if File.exists?(path) do
      Editor.edit_file(path)
    else
      case Editor.edit_text(target) do
        {:ok, text} when byte_size(text) > 0 ->
          IO.puts(Formatter.format_info("Sending prompt written via $EDITOR…"))
          Session.send_user_message(session_pid, text)

        _ ->
          :ok
      end
    end

    :continue
  end

  def handle_input("/endpoint " <> target, session_pid, _session_id) do
    target_endpoint =
      case String.trim(target) do
        "default" -> "https://api.deepseek.com/chat/completions"
        "deepseek" -> "https://api.deepseek.com/chat/completions"
        "openrouter" -> "https://openrouter.ai/api/v1/chat/completions"
        "ollama" -> "http://localhost:11434/v1/chat/completions"
        "lmstudio" -> "http://localhost:1234/v1/chat/completions"
        "vllm" -> "http://localhost:8000/v1/chat/completions"
        other -> other
      end

    {:ok, current} = Session.set_endpoint(session_pid, target_endpoint)
    IO.puts(Formatter.format_success("Switched endpoint to '#{current}'"))
    :continue
  end

  def handle_input("/endpoint", _session_pid, _session_id) do
    IO.puts(
      Formatter.format_error(
        "Usage: /endpoint <url|default|deepseek|openrouter|ollama|lmstudio|vllm>"
      )
    )

    :continue
  end

  def handle_input("/config style " <> style, _session_pid, _session_id) do
    s = String.trim(style)
    cfg = Yoke.Config.load_config()
    updated = Map.put(cfg, "prompt_style", s)
    Yoke.Config.save_config(updated)
    IO.puts(Formatter.format_success("Prompt style set to '#{s}'"))
    :continue
  end

  def handle_input("/config style", _session_pid, _session_id) do
    IO.puts(Formatter.format_error("Usage: /config style <starship|extended|compact|minimal>"))

    :continue
  end

  def handle_input("/config prompt " <> format_str, _session_pid, _session_id) do
    fmt = String.trim(format_str)
    cfg = Yoke.Config.load_config()
    updated = Map.merge(cfg, %{"prompt_style" => "custom", "prompt_format" => fmt})
    Yoke.Config.save_config(updated)
    IO.puts(Formatter.format_success("Custom prompt format set to '#{fmt}'"))
    :continue
  end

  def handle_input("/config prompt", _session_pid, _session_id) do
    IO.puts(
      Formatter.format_error(
        "Usage: /config prompt <template> (placeholders: {session}, {model}, {mode}, {tasks})"
      )
    )

    :continue
  end

  def handle_input("/config toggle " <> key, _session_pid, _session_id) do
    k = String.trim(key)
    cfg = Yoke.Config.load_config()
    current = Map.get(cfg, k, true)
    updated = Map.put(cfg, k, not current)
    Yoke.Config.save_config(updated)

    IO.puts(Formatter.format_success("Toggled config setting '#{k}' to #{not current}"))

    :continue
  end

  def handle_input("/explorer", _session_pid, _session_id) do
    Yoke.CLI.ConfigExplorer.run()
    :continue
  end

  def handle_input("/config explorer", _session_pid, _session_id) do
    Yoke.CLI.ConfigExplorer.run()
    :continue
  end

  def handle_input("/config toggle", _session_pid, _session_id) do
    IO.puts(
      Formatter.format_error(
        "Usage: /config toggle <setting_key> (e.g. enable_autosuggestions, enable_syntax_highlighting)"
      )
    )

    :continue
  end

  def handle_input("/config", _session_pid, _session_id) do
    cfg = Yoke.Config.load_config()

    rows =
      cfg
      |> Enum.sort()
      |> Enum.map_join("\n", fn {k, v} -> "- **`#{k}`**: `#{inspect(v)}`" end)

    md = """
    ### Yoke CLI Configuration & UI Preferences
    #{rows}

    **Usage:**
    - `/config style <starship|extended|compact|minimal>` — Switch prompt visual layout style
    - `/config prompt <template>` — Set custom prompt template (placeholders: `{session}`, `{model}`, `{mode}`, `{tasks}`)
    - `/config toggle <setting_key>` — Toggle feature on/off (e.g. `enable_autosuggestions`, `enable_syntax_highlighting`, `enable_context_gauge`, `compact_status_bar`)

    **Status Bar:** The ruler line above the prompt shows, in priority order:
    1. An active parallel task badge whenever the OTP TaskEngine is running
       background tool calls.
    2. Otherwise, an ambient segment (permission mode, sandbox bounds,
       connected MCP server count, registered tool count, and a `●` dot when
       the workspace has uncommitted git changes) plus a toggleable segment:
       either the token/cost gauge with per-turn `(+N)` delta and `/compact`
       warnings as usage climbs, or a compact `id + message count` line.
    3. A plain divider when disabled entirely via `/config toggle enable_context_gauge`.

    Override the assumed context window size by adding `"max_context_tokens": <n>`
    to `.yoke/config.json`. While the agent is "thinking", the spinner also shows
    elapsed turn time and the live OTP parallel task count.

    Cap how many tokens each API request may generate by adding
    `"max_tokens": <n>` to `.yoke/config.json` (or `~/.yoke/config.json`). The
    value is sent as the `max_tokens` field on every DeepSeek chat-completions
    request. Omit it (or set `null`) to let the provider apply its own default;
    tune it per model/provider (e.g. `deepseek-reasoner`) as needed.

    Set the model's per-million-token prices (used for the status bar cost
    gauge, `/cost`, and `/stats`) by adding `"price_per_million_prompt_tokens": <n>`
    and `"price_per_million_completion_tokens": <n>` to `~/.yoke/config.json`
    (USD per 1M tokens; defaults: prompt 0.14, completion 0.28). Set them
    globally when you use a model/provider other than DeepSeek V3 so the
    reported cost reflects your actual rate.

    Override how many consecutive tool-calling turns a single agent loop
    runs before pausing to ask whether to continue by adding
    `"max_tool_depth": <n>` to `.yoke/config.json` (default: `1000`).

    **Hotkeys:** `Ctrl+P` toggles permission mode, `Ctrl+G` toggles sandbox
    bounds, `Ctrl+B` toggles the idle status bar between gauge and compact mode
    (same as `/config toggle compact_status_bar`).
    """

    IO.puts("\n" <> Formatter.format_markdown(md) <> "\n")
    :continue
  end

  def handle_input("/update", _session_pid, _session_id) do
    Yoke.CLI.Main.handle_self_update()
    :continue
  end

  def handle_input("/rules add " <> rest, _session_pid, _session_id) do
    case Yoke.Rules.add_rule(rest) do
      {:ok, rule} ->
        IO.puts(
          Formatter.format_success(
            "Added rule ##{rule["id"]} [#{rule["scope"]}]: \"#{rule["text"]}\""
          )
        )

      {:error, err} ->
        IO.puts(Formatter.format_error(err))
    end

    :continue
  end

  def handle_input("/rules delete", _session_pid, _session_id), do: handle_rules_delete()
  def handle_input("/rules rm", _session_pid, _session_id), do: handle_rules_delete()

  def handle_input("/rules toggle " <> id_str, _session_pid, _session_id) do
    case Yoke.Rules.toggle_rule(id_str) do
      {:ok, _rules} ->
        IO.puts(Formatter.format_success("Toggled rule ##{id_str} status."))

      {:error, err} ->
        IO.puts(Formatter.format_error(err))
    end

    :continue
  end

  def handle_input("/rules", _session_pid, _session_id) do
    rules = Yoke.Rules.load_rules()

    rows =
      if Enum.empty?(rules) do
        "*No rules currently defined.*"
      else
        rules
        |> Enum.map_join("\n", fn r ->
          status = if r["enabled"], do: "enabled", else: "disabled"
          "| ##{r["id"]} | `#{r["scope"]}` | #{status} | #{r["text"]} |"
        end)
      end

    md = """
    ### Active Prompt & Execution Rules (#{length(rules)})
    | ID | Scope | Status | Rule Text |
    |---|---|---|---|
    #{rows}

    **Commands:**
    - `/rules add <scope: text>` — Add a new rule (e.g. `/rules add all: ...`, `/rules add cr: ...`)
    - `/rules delete` or `/rules rm` — Interactively select rules to delete
    - `/rules toggle <id>` — Toggle rule enabled/disabled
    """

    IO.puts("\n" <> Formatter.format_markdown(md) <> "\n")
    :continue
  end

  def handle_input("/practices add " <> rest, _session_pid, _session_id) do
    langs = Yoke.Practices.detect_languages()
    lang = Enum.at(langs, 0) || "elixir"

    case Yoke.Practices.add_practice(lang, rest) do
      {:ok, item} ->
        IO.puts(
          Formatter.format_success(
            "Added practice for '#{lang}' globally (~/.yoke) & locally (.yoke):\n  \"#{item}\""
          )
        )

      {:error, err} ->
        IO.puts(Formatter.format_error(err))
    end

    :continue
  end

  def handle_input("/practices learn " <> args, _session_pid, _session_id),
    do: handle_practices_learn(args)

  def handle_input("/practices squeeze " <> args, _session_pid, _session_id),
    do: handle_practices_learn(args)

  def handle_input("/practices delete", _session_pid, _session_id),
    do: handle_practices_delete()

  def handle_input("/practices rm", _session_pid, _session_id),
    do: handle_practices_delete()

  def handle_input("/practices edit", _session_pid, _session_id) do
    langs = Yoke.Practices.detect_languages()
    lang = Enum.at(langs, 0) || "elixir"
    path = Yoke.Practices.local_practice_path(lang)
    g_path = Yoke.Practices.global_practice_path(lang)

    IO.puts(Formatter.format_info("Practice files:\n  - Local: #{path}\n  - Global: #{g_path}"))

    Editor.edit_file(path)
    :continue
  end

  def handle_input("/practices", _session_pid, _session_id) do
    langs = Yoke.Practices.detect_languages()

    if Enum.empty?(langs) do
      IO.puts(
        Formatter.format_info("No specific programming language detected in workspace root.")
      )
    else
      Enum.each(langs, fn lang ->
        p = Yoke.Practices.load_practices(lang)
        g_path = Yoke.Practices.global_practice_path(lang)
        l_path = Yoke.Practices.local_practice_path(lang)

        items_str =
          if Enum.empty?(p.items) do
            "*No practices defined yet.*"
          else
            p.items
            |> Enum.with_index(1)
            |> Enum.map_join("\n", fn {item, idx} -> "#{idx}. #{item}" end)
          end

        md = """
        ### Good Practices for #{String.capitalize(lang)} (.lmml format)
        - **Global (~/.yoke):** `#{g_path}`
        - **Local (.yoke):** `#{l_path}`

        #{items_str}

        **Commands:**
        - `/practices add <text>` — Add a new practice
        - `/practices delete` or `/practices rm` — Delete practice items
        - `/practices learn <paths...>` — Squeeze practices from exemplary project directories
        - `/practices edit` — Open practice file in $EDITOR
        """

        IO.puts("\n" <> Formatter.format_markdown(md) <> "\n")
      end)
    end

    :continue
  end

  def handle_input("/plan on", _session_pid, _session_id) do
    cfg = Yoke.Config.load_config()
    updated = Map.put(cfg, "plan_gate_enabled", true)
    Yoke.Config.save_config(updated)

    IO.puts(
      Formatter.format_success(
        "Plan gate ENABLED (threshold: #{cfg["plan_gate_threshold"]} modifying tool calls)"
      )
    )

    :continue
  end

  def handle_input("/plan off", _session_pid, _session_id) do
    cfg = Yoke.Config.load_config()
    updated = Map.put(cfg, "plan_gate_enabled", false)
    Yoke.Config.save_config(updated)
    IO.puts(Formatter.format_success("Plan gate DISABLED"))
    :continue
  end

  def handle_input("/plan status", _session_pid, _session_id) do
    cfg = Yoke.Config.load_config()
    plan_gate_status(cfg)
    :continue
  end

  def handle_input("/plan", _session_pid, _session_id) do
    cfg = Yoke.Config.load_config()
    plan_gate_status(cfg)
    :continue
  end

  def handle_input("/plan " <> other, _session_pid, _session_id) do
    other = String.trim(other)

    IO.puts(
      Formatter.format_error("Unknown /plan option '#{other}'. Usage: /plan [on | off | status]")
    )

    :continue
  end

  def handle_input("/god on", _session_pid, _session_id) do
    cfg = Yoke.Config.load_config()
    updated = Map.put(cfg, "god_mode", true)
    Yoke.Config.save_config(updated)
    Application.put_env(:yoke, :god_mode, true)

    IO.puts(
      Formatter.format_success(
        "God mode ENABLED (all model questions and confirmations will be auto-answered without user input)"
      )
    )

    :continue
  end

  def handle_input("/god off", _session_pid, _session_id) do
    cfg = Yoke.Config.load_config()
    updated = Map.put(cfg, "god_mode", false)
    Yoke.Config.save_config(updated)
    Application.put_env(:yoke, :god_mode, false)
    IO.puts(Formatter.format_success("God mode DISABLED"))
    :continue
  end

  def handle_input("/god status", _session_pid, _session_id) do
    cfg = Yoke.Config.load_config()
    god_mode_status(cfg)
    :continue
  end

  def handle_input("/god toggle", _session_pid, _session_id) do
    cfg = Yoke.Config.load_config()
    current = Map.get(cfg, "god_mode", false)
    new_mode = not current
    updated = Map.put(cfg, "god_mode", new_mode)
    Yoke.Config.save_config(updated)
    Application.put_env(:yoke, :god_mode, new_mode)

    status_str =
      if new_mode, do: "ENABLED (all questions & confirmations auto-answered)", else: "DISABLED"

    IO.puts(Formatter.format_success("God mode #{status_str}"))
    :continue
  end

  def handle_input("/god", session_pid, session_id) do
    handle_input("/god toggle", session_pid, session_id)
  end

  def handle_input("/god " <> other, _session_pid, _session_id) do
    other = String.trim(other)

    IO.puts(
      Formatter.format_error(
        "Unknown /god option '#{other}'. Usage: /god [on | off | status | toggle]"
      )
    )

    :continue
  end

  def handle_input("/mode " <> args, session_pid, _session_id) do
    parts = String.split(args, " ", trim: true)

    case parts do
      ["remote", node_str] ->
        Session.set_hands_mode(session_pid, :remote, node_str)
        IO.puts(Formatter.format_success("Hands target set to remote node: #{node_str}"))

      ["docker", container] ->
        Session.set_hands_mode(session_pid, :docker, container)
        IO.puts(Formatter.format_success("Hands target set to docker container: #{container}"))

      ["local"] ->
        Session.set_hands_mode(session_pid, :local)
        IO.puts(Formatter.format_success("Hands target set to local sandbox"))

      _ ->
        IO.puts(
          Formatter.format_error(
            "Usage: /mode [local | remote <node_name> | docker <container_id>]"
          )
        )
    end

    :continue
  end

  def handle_input("/checkpoint" <> rest, session_pid, _session_id) do
    label = String.trim(rest)
    label = if label == "", do: nil, else: label

    {:ok, cp} = Session.checkpoint(session_pid, label)
    IO.puts(Formatter.format_success("Saved snapshot: '#{cp.label}' (ID: #{cp.id})"))
    :continue
  end

  def handle_input("/undo", session_pid, _session_id) do
    case Session.undo(session_pid) do
      {:ok, msg} ->
        IO.puts(Formatter.format_success(msg))

      {:error, err} ->
        IO.puts(Formatter.format_error(err))
    end

    :continue
  end

  def handle_input("/session review " <> target_id, session_pid, session_id) do
    handle_review_conversation(target_id, session_pid, session_id)
  end

  def handle_input("/session review", session_pid, session_id) do
    handle_review_conversation(nil, session_pid, session_id)
  end

  def handle_input("/session list", _session_pid, _session_id) do
    metas = Yoke.Brain.SessionStore.list_session_metadata()

    rows =
      if Enum.empty?(metas) do
        "*No persisted sessions found in workspace.*"
      else
        Enum.map_join(metas, "\n", fn m ->
          dt = m.updated_at |> NaiveDateTime.to_iso8601() |> String.slice(0, 19)
          title_prefix = if m[:title], do: "**\"#{m.title}\"** ", else: ""

          "- #{title_prefix}`#{m.session_id}` [#{m.model}]: #{m.message_count} msgs, step #{m.step_count} (Updated: `#{dt}`)"
        end)
      end

    md = "### Persisted Workspace Sessions (#{length(metas)})\n\n#{rows}"
    IO.puts("\n" <> Formatter.format_markdown(md) <> "\n")
    :continue
  end

  def handle_input("/session resume " <> target_id, session_pid, session_id) do
    handle_input("/session switch " <> target_id, session_pid, session_id)
  end

  def handle_input("/resume " <> target_id, session_pid, session_id) do
    clean_id =
      target_id
      |> String.trim()
      |> String.replace(~r/^--conversation=|^ -c |^-c=/, "")

    handle_input("/session switch " <> clean_id, session_pid, session_id)
  end

  def handle_input("/resume", session_pid, session_id) do
    metas = Yoke.Brain.SessionStore.list_session_metadata()

    if Enum.empty?(metas) do
      IO.puts(Formatter.format_info("No saved sessions available to resume."))
      :continue
    else
      meta_map =
        Enum.into(metas, %{}, fn m ->
          {format_session_picker_label(m), m.session_id}
        end)

      opts = Enum.map(metas, &format_session_picker_label/1)

      ans =
        Yoke.CLI.Spinner.with_paused(fn ->
          Yoke.CLI.QuestionPrompt.ask_single_question(
            "Select conversation to resume:",
            opts,
            false,
            false
          )
        end)

      case ans do
        %{selected: [sel]} ->
          target_id = Map.get(meta_map, sel) || sel |> String.split(" ", parts: 2) |> List.first()
          handle_input("/session switch " <> target_id, session_pid, session_id)

        _ ->
          :continue
      end
    end
  end

  def handle_input("/session switch " <> target_id, _session_pid, _session_id) do
    id = String.trim(target_id)

    new_pid =
      case Yoke.Brain.SessionSupervisor.start_session(session_id: id) do
        {:ok, pid} -> pid
        {:error, {:already_started, pid}} -> pid
      end

    IO.puts(Formatter.format_success("Switched active REPL session to '#{id}'"))
    {:switch_session, id, new_pid}
  end

  def handle_input("/session cleanup", _session_pid, _session_id) do
    metas = Yoke.Brain.SessionStore.list_session_metadata()
    stale = Enum.filter(metas, fn m -> m.message_count <= 1 end)

    removed_count =
      Enum.count(stale, fn m ->
        match?({:ok, _}, Yoke.Brain.SessionStore.delete_session(m.session_id))
      end)

    IO.puts(Formatter.format_success("Cleaned up #{removed_count} stale/empty session(s)."))
    :continue
  end

  def handle_input("/status", session_pid, session_id) do
    handle_input("/session", session_pid, session_id)
  end

  def handle_input("/session", session_pid, _session_id) do
    info = Session.get_info(session_pid)

    md = """
    ### Active Session & System Status
    - **Session ID**: `#{info.session_id}`
    - **Actor PID**: `#{inspect(info.pid)}`
    - **Model**: `#{info.model}`
    - **Permission Mode**: `#{info.permission_mode}`
    - **History Length**: `#{info.message_count}` messages
    - **Checkpoints**: `#{info.snapshot_count}` snapshots
    - **Hands Execution Target**: `#{info.hands_mode}` (`#{info.hands_target}`)
    - **Active Tools Count**: `#{info.tools_count}` registered
    - **Serving BEAM Processes**: `#{info.serving_processes}` active (`#{info.active_task_workers}` parallel task workers)
    - **System Process Status**: `#{info.serving_report}`
    """

    IO.puts("\n" <> Formatter.format_markdown(md) <> "\n")
    :continue
  end

  def handle_input("/history search " <> query, _session_pid, _session_id) do
    q = String.downcase(String.trim(query))
    history = Yoke.CLI.LineEditor.load_history()
    matches = Enum.filter(history, fn line -> String.contains?(String.downcase(line), q) end)

    md =
      if Enum.empty?(matches) do
        "No history entries matching '#{query}'."
      else
        rows = Enum.map_join(matches, "\n", fn m -> "- `#{m}`" end)
        "### History Search Results for '#{query}' (#{length(matches)})\n\n#{rows}"
      end

    IO.puts("\n" <> Formatter.format_markdown(md) <> "\n")
    :continue
  end

  def handle_input("/history", _session_pid, _session_id) do
    history = Yoke.CLI.LineEditor.load_history()
    recent = Enum.take(Enum.reverse(history), 15)

    rows =
      if Enum.empty?(recent) do
        "*No REPL input history found.*"
      else
        recent
        |> Enum.with_index(1)
        |> Enum.map_join("\n", fn {line, idx} -> "  #{idx}. `#{line}`" end)
      end

    md = "### Recent Input History (Last 15)\n\n#{rows}"
    IO.puts("\n" <> Formatter.format_markdown(md) <> "\n")
    :continue
  end

  def handle_input("/env", _session_pid, _session_id) do
    env_model = System.get_env("DEEPSEEK_MODEL") || "deepseek-chat (default)"

    has_key? =
      not is_nil(System.get_env("DEEPSEEK_API_KEY")) and
        System.get_env("DEEPSEEK_API_KEY") != ""

    yoke_env = System.get_env("YOKE_ENV") || "prod"
    cwd = File.cwd!()

    md = """
    ### Environment & Runtime Configuration
    - **Operating System**: `#{:os.type() |> inspect()}`
    - **Elixir Version**: `#{System.version()}`
    - **OTP Release**: `#{System.otp_release()}`
    - **Current Workspace CWD**: `#{cwd}`
    - **Node Name**: `#{node()}`
    - **Environment**: `#{yoke_env}`
    - **DEEPSEEK_MODEL**: `#{env_model}`
    - **API Key Set?**: `#{has_key?}`
    """

    IO.puts("\n" <> Formatter.format_markdown(md) <> "\n")
    :continue
  end

  def handle_input("/plugins info", _session_pid, _session_id) do
    tools = PluginLoader.list_tools()
    rows = Enum.map_join(tools, "\n", fn t -> "- **`#{t.name}`**: #{t.description}" end)
    md = "### Registered Plugin Tools Info (#{length(tools)})\n\n#{rows}"
    IO.puts("\n" <> Formatter.format_markdown(md) <> "\n")
    :continue
  end

  def handle_input("/ragex stats", _session_pid, _session_id) do
    case MCPServerManager.execute_ragex_tool("graph_stats", %{}) do
      {:ok, out} ->
        IO.puts(
          "\n" <> Formatter.format_markdown("### Ragex Knowledge Graph Stats\n\n#{out}") <> "\n"
        )

      {:error, err} ->
        IO.puts(Formatter.format_error(err))
    end

    :continue
  end

  def handle_input("/ragex reindex", _session_pid, _session_id) do
    IO.puts(Formatter.format_info("Re-indexing project codebase into Ragex Knowledge Graph…"))

    case MCPServerManager.start_ragex(File.cwd!()) do
      {:ok, _dir, _tools} ->
        IO.puts(Formatter.format_success("Knowledge Graph re-indexing triggered successfully!"))

      {:error, err} ->
        IO.puts(Formatter.format_error(err))
    end

    :continue
  end

  def handle_input("/ragex url " <> url_str, _session_pid, _session_id) do
    target_url = String.trim(url_str)

    IO.puts(
      Formatter.format_info("Analyzing URL with Ragex URL Analyzer Engine: '#{target_url}'…")
    )

    case MCPServerManager.execute_ragex_tool("analyze_url", %{"url" => target_url}) do
      {:ok, out} ->
        IO.puts(
          "\n" <> Formatter.format_markdown("### Ragex URL Analysis Report\n\n#{out}") <> "\n"
        )

      {:error, err} ->
        IO.puts(Formatter.format_error(err))
    end

    :continue
  end

  def handle_input("/ragex audit", _session_pid, _session_id) do
    IO.puts(Formatter.format_info("Running Ragex Security Audit against codebase…"))

    case MCPServerManager.execute_ragex_tool("security_audit", %{}) do
      {:ok, out} ->
        IO.puts(
          "\n" <> Formatter.format_markdown("### Ragex Security Audit Report\n\n#{out}") <> "\n"
        )

      {:error, err} ->
        IO.puts(Formatter.format_error(err))
    end

    :continue
  end

  def handle_input("/ragex quality", _session_pid, _session_id) do
    IO.puts(Formatter.format_info("Running Ragex Code Quality Analysis against codebase…"))

    case MCPServerManager.execute_ragex_tool("quality_report", %{}) do
      {:ok, out} ->
        IO.puts(
          "\n" <> Formatter.format_markdown("### Ragex Code Quality Report\n\n#{out}") <> "\n"
        )

      {:error, err} ->
        IO.puts(Formatter.format_error(err))
    end

    :continue
  end

  def handle_input("/ragex help", _session_pid, _session_id) do
    md = """
    ### Ragex 0.30 Code Intelligence Commands
    - `/ragex` — Mount Ragex MCP server for local workspace
    - `/ragex stats` — View Knowledge Graph statistics (nodes, edges, top PageRank modules)
    - `/ragex url <url>` — Analyze external repository (GitHub/GitLab), web page, or API spec
    - `/ragex audit` — Run automated Security Audit scanning
    - `/ragex quality` — Run Code Quality and complexity report
    - `/ragex reindex` — Re-index workspace codebase into Knowledge Graph
    - `/ragex export [mermaid|dot|d3]` — Export Knowledge Graph visual structure
    """

    IO.puts("\n" <> Formatter.format_markdown(md) <> "\n")
    :continue
  end

  def handle_input("/ragex export " <> fmt, _session_pid, _session_id) do
    format = String.trim(fmt)

    case MCPServerManager.execute_ragex_tool("export_graph", %{"format" => format}) do
      {:ok, out} ->
        IO.puts(
          "\n" <>
            Formatter.format_markdown(
              "### Knowledge Graph Export (#{format})\n\n```\n#{out}\n```"
            ) <> "\n"
        )

      {:error, err} ->
        IO.puts(Formatter.format_error(err))
    end

    :continue
  end

  def handle_input("/ragex export", session_pid, session_id) do
    handle_input("/ragex export mermaid", session_pid, session_id)
  end

  def handle_input("/nodes", _session_pid, _session_id) do
    data = NodeManager.list_nodes()

    md = """
    ### Distributed Erlang Node Cluster
    - **Local Node**: `#{data.self}`
    - **Node Alive?**: `#{data.alive?}`
    - **Connected Nodes**: `#{inspect(data.connected)}`
    """

    IO.puts("\n" <> Formatter.format_markdown(md) <> "\n")
    :continue
  end

  def handle_input("/workflow list", _session_pid, _session_id) do
    metas = Yoke.Workflow.Definition.list()

    rows =
      if Enum.empty?(metas) do
        "*No workflows discovered.*"
      else
        Enum.map_join(metas, "\n", fn m ->
          "- **`#{m.name}`** (#{m.source}): #{m.description}"
        end)
      end

    md = """
    ### Available Workflows (#{length(metas)})

    #{rows}

    Run one with `/workflow run <name> <task description>`. Scaffold a custom
    one with `/workflow init <name> [--from <template>]`.
    """

    IO.puts("\n" <> Formatter.format_markdown(md) <> "\n")
    :continue
  end

  def handle_input("/workflow init " <> rest, _session_pid, _session_id) do
    case String.split(String.trim(rest), " ", trim: true) do
      [name, "--from", template] -> do_workflow_init(name, template)
      [name] -> do_workflow_init(name, "elixir")
      _ -> IO.puts(Formatter.format_error("Usage: /workflow init <name> [--from <template>]"))
    end

    :continue
  end

  def handle_input("/workflow run " <> rest, _session_pid, _session_id) do
    case String.split(String.trim(rest), " ", parts: 2) do
      [name, description] -> do_workflow_run(name, description)
      [name] -> do_workflow_run(name, "")
      _ -> IO.puts(Formatter.format_error("Usage: /workflow run <name> <task description>"))
    end

    :continue
  end

  def handle_input("/workflow status " <> run_id, _session_pid, _session_id) do
    do_workflow_status(String.trim(run_id))
    :continue
  end

  def handle_input("/workflow status", _session_pid, _session_id) do
    metas = Yoke.Workflow.Store.list_runs()

    rows =
      if Enum.empty?(metas) do
        "*No workflow runs found in this workspace.*"
      else
        Enum.map_join(metas, "\n", fn m ->
          "- `#{m.run_id}` [#{m.workflow}] — **#{m.status}** (step #{m.step_index}, branch `#{m.branch}`, updated #{m.updated_at})"
        end)
      end

    md =
      "### Workflow Runs (#{length(metas)})\n\n#{rows}\n\nInspect one with `/workflow status <run-id>`."

    IO.puts("\n" <> Formatter.format_markdown(md) <> "\n")
    :continue
  end

  def handle_input("/workflow resume " <> run_id, _session_pid, _session_id) do
    do_workflow_resume(String.trim(run_id))
    :continue
  end

  def handle_input("/workflow abort " <> run_id, _session_pid, _session_id) do
    id = String.trim(run_id)

    case Yoke.Workflow.Engine.abort(id) do
      {:ok, _state} ->
        IO.puts(Formatter.format_success("Marked workflow run '#{id}' as aborted."))

      {:error, err} ->
        IO.puts(Formatter.format_error(err))
    end

    :continue
  end

  def handle_input("/workflow", _session_pid, _session_id) do
    IO.puts(
      Formatter.format_info(
        "Usage: /workflow [list | run <name> <description> | status [run-id] | resume <run-id> | abort <run-id> | init <name> [--from <template>]]"
      )
    )

    :continue
  end

  # Catch any unknown slash command to avoid sending accidental mistyped commands to LLM
  def handle_input("/" <> command, _session_pid, _session_id) do
    IO.puts(
      Formatter.format_error(
        "Unknown command '/#{command}'. Type /help for available slash commands."
      )
    )

    :continue
  end

  def handle_input(user_prompt, session_pid, _session_id) do
    turn_fn = fn -> try_send_message(session_pid, user_prompt) end

    res =
      Yoke.CLI.Spinner.run(
        fn -> Yoke.CLI.Interrupt.run(session_pid, turn_fn) end,
        title: "Thinking & coordinating with Hands… (Ctrl+Q to interrupt)"
      )

    case res do
      {:ok, %{content: content}} ->
        IO.puts("\n" <> Formatter.format_agent_response(content) <> "\n")
        # Flush so the response is guaranteed on the terminal before the
        # LineEditor re-enters raw mode to redraw the prompt -- otherwise a
        # buffered response can be swallowed/corrupted by the next raw-mode
        # render, leaving an "empty screen" where the response should be.
        Formatter.flush()

      {:error, reason} ->
        IO.puts(Formatter.format_error("Turn failed: #{reason}"))
        Formatter.flush()
    end

    :continue
  end

  # Helper to safely send message and handle potential actor exits gracefully
  defp try_send_message(session_pid, user_prompt) do
    Session.send_user_message(session_pid, user_prompt)
  catch
    :exit, reason ->
      {:error, "Session process crashed or stopped: #{inspect(reason)}"}
  end

  # Returns the token count consumed by the most recently completed turn, or
  # 0 before any turn has run. Used to show a "(+N)" delta on the status
  # bar's context gauge instead of only the cumulative running total.
  defp latest_turn_delta(session_pid) do
    case Session.get_turn_tokens(session_pid) do
      [] -> 0
      turns -> turns |> List.last() |> Map.get(:total_tokens, 0)
    end
  end

  defp ensure_session_alive(pid, session_id) do
    if is_pid(pid) and Process.alive?(pid) do
      pid
    else
      via = Session.via_tuple(session_id)

      case GenServer.whereis(via) do
        nil ->
          IO.puts(Formatter.format_info("Restarting agent session actor '#{session_id}'…"))
          {:ok, new_pid} = SessionSupervisor.start_session(session_id: session_id)
          new_pid

        new_pid ->
          new_pid
      end
    end
  end

  defp handle_mcp_list(_session_pid, _session_id) do
    servers = MCPServerManager.list_servers()

    md =
      if Enum.empty?(servers) do
        "### Connected MCP Servers (0)\n*No MCP servers connected. Use `/mcp add <name> <cmd> [args...]`, `/mcp load`, or `/ragex`.*"
      else
        server_blocks = Enum.map_join(servers, "\n\n", &format_server_block/1)
        "### Connected MCP Servers (#{length(servers)})\n\n" <> server_blocks
      end

    IO.puts("\n" <> Formatter.format_markdown(md) <> "\n")
    :continue
  end

  defp format_server_block(s) do
    tools_list = Enum.map_join(s.tools, "\n", fn t -> "  - `#{t}`" end)

    "#### #{s.name} (`#{s.command} #{Enum.join(s.args, " ")}`)\n**Registered Tools (#{s.tools_count}):**\n#{tools_list}"
  end

  defp handle_import_session(path, session_id) do
    opts = [session_id: session_id, overwrite: false]

    case Yoke.Brain.SessionStore.import_session(path, opts) do
      {:ok, imported_id, file_path} ->
        IO.puts(
          Formatter.format_success(
            "Imported session '#{imported_id}' -> #{file_path}. Resume with /session resume #{imported_id} or /resume #{imported_id}."
          )
        )

      {:error, err} ->
        IO.puts(Formatter.format_error(err))
    end
  end

  defp do_workflow_init(name, template) do
    case Yoke.Workflow.Definition.init(name, template) do
      {:ok, path} ->
        IO.puts(
          Formatter.format_success(
            "Scaffolded workflow '#{name}' from template '#{template}' -> #{path}. Edit it, then run with /workflow run #{name}."
          )
        )

      {:error, err} ->
        IO.puts(Formatter.format_error(err))
    end
  end

  defp do_workflow_run(name, description) do
    IO.puts(Formatter.format_info("Starting workflow '#{name}'…"))

    case Yoke.Workflow.Engine.run(name, seed_prompt: description) do
      {:ok, context} ->
        IO.puts(
          Formatter.format_success("Workflow '#{name}' completed (run '#{context.run_id}').")
        )

      {:halt, reason} ->
        IO.puts(Formatter.format_info("Workflow halted: #{reason}"))

      {:error, reason} ->
        IO.puts(Formatter.format_error("Workflow failed: #{inspect(reason)}"))
    end
  end

  defp do_workflow_resume(run_id) do
    IO.puts(Formatter.format_info("Resuming workflow run '#{run_id}'…"))

    case Yoke.Workflow.Engine.resume(run_id) do
      {:ok, _context} ->
        IO.puts(Formatter.format_success("Workflow run '#{run_id}' completed."))

      {:halt, reason} ->
        IO.puts(Formatter.format_info("Workflow halted: #{reason}"))

      {:error, reason} ->
        IO.puts(
          Formatter.format_error("Failed to resume workflow run '#{run_id}': #{inspect(reason)}")
        )
    end
  end

  defp do_workflow_status(run_id) do
    case Yoke.Workflow.Engine.status(run_id) do
      {:ok, state} ->
        reason_line = if state["reason"], do: "- **Reason**: #{state["reason"]}\n", else: ""

        md = """
        ### Workflow Run `#{run_id}`
        - **Workflow**: `#{state["workflow"]}`
        - **Status**: `#{state["status"]}`
        - **Step**: `#{state["step_index"]}`
        - **Branch**: `#{state["branch"]}`
        - **Base Branch**: `#{state["base_branch"]}`
        - **Updated**: `#{state["updated_at"]}`
        #{reason_line}
        """

        IO.puts("\n" <> Formatter.format_markdown(md) <> "\n")

      {:error, err} ->
        IO.puts(Formatter.format_error(err))
    end
  end

  defp handle_copy_clipboard(session_pid, _session_id) do
    case Session.get_latest_response(session_pid) do
      {:ok, content} ->
        case Formatter.copy_to_clipboard(content) do
          :ok ->
            IO.puts(
              Formatter.format_success(
                "Copied latest assistant response to clipboard (#{String.length(content)} characters)!"
              )
            )

          {:error, err} ->
            IO.puts(Formatter.format_error(err))
        end

      {:error, err} ->
        IO.puts(Formatter.format_error(err))
    end

    :continue
  end

  defp plan_gate_status(cfg) do
    enabled = Map.get(cfg, "plan_gate_enabled", true)
    threshold = Map.get(cfg, "plan_gate_threshold", 2)

    state =
      if enabled do
        "enabled"
      else
        "disabled"
      end

    IO.puts(
      Formatter.format_info("Plan gate: #{state} (threshold: #{threshold} modifying tool calls)")
    )
  end

  defp god_mode_status(cfg) do
    enabled? = Map.get(cfg, "god_mode", false)

    state =
      if enabled? do
        "enabled (auto-answering all model questions & confirmations)"
      else
        "disabled"
      end

    IO.puts(Formatter.format_info("God mode: #{state}"))
  end

  # ---------------------------------------------------------------------
  # /skills helpers
  # ---------------------------------------------------------------------

  defp split_skill_invocation(rest) do
    case String.split(String.trim(rest), " ", parts: 2) do
      [name, args] -> {name, args}
      [name] -> {name, ""}
      _ -> {"", ""}
    end
  end

  defp print_skills_list(skills) do
    skill_rows =
      if Enum.empty?(skills) do
        "*No skills discovered in `.yoke/skills`, `~/.yoke/skills`, or the builtin skills dir.*"
      else
        Enum.map_join(skills, "\n", &format_skill_row/1)
      end

    shadow_warning =
      case SkillManager.shadowed(skills) do
        [] ->
          ""

        shadowed ->
          names =
            Enum.map_join(shadowed, ", ", fn {n, win, lose} ->
              "`#{n}` (#{lose} shadowed by #{win})"
            end)

          "\n\n> ⚠ Shadowed skills: #{names}"
      end

    md = """
    ### Discovered Skills (#{length(skills)})

    #{skill_rows}#{shadow_warning}

    Execute one with `/skills <name>`, inspect with `/skills show <name>`, or
    scaffold a new one with `/skills new <name>`.
    """

    IO.puts("\n" <> Formatter.format_markdown(md) <> "\n")
  end

  defp format_skill_row(%SkillManager{error: error} = s) when is_binary(error) do
    "- ⚠ **`#{s.name}`** (#{s.scope}): #{error} — *skipped*"
  end

  defp format_skill_row(%SkillManager{} = s) do
    shadow = if s.shadowed_by, do: " _(shadows #{s.shadowed_by})_", else: ""
    "- **`#{s.name}`** (#{s.scope}): #{s.description}#{shadow}\n  `#{s.path}`"
  end

  defp with_skill(name, fun) do
    name = String.trim(name)
    skills = SkillManager.discover_skills()

    case SkillManager.find_skill(skills, name) do
      {:ok, skill} ->
        fun.(skill)

      {:error, :not_found} ->
        IO.puts(Formatter.format_error(skill_not_found_message(skills, name)))
    end
  end

  defp execute_skill(name, args, opts) do
    skills = SkillManager.discover_skills()

    skills =
      if Keyword.get(opts, :global, false) do
        Enum.filter(skills, &(&1.scope == :global))
      else
        skills
      end

    case SkillManager.find_skill(skills, name) do
      {:ok, %SkillManager{error: error}} when is_binary(error) ->
        IO.puts(Formatter.format_error("Skill '#{name}' is invalid: #{error}"))

      {:ok, skill} ->
        run_skill(skill, args, opts)

      {:error, :not_found} ->
        IO.puts(Formatter.format_error(skill_not_found_message(skills, name)))
    end
  end

  defp run_skill(skill, args, opts) do
    session_pid = Keyword.fetch!(opts, :session_pid)
    body = SkillManager.render(skill, args)

    prompt =
      if args == "" do
        "Execute skill '#{skill.name}':\n\n#{body}"
      else
        "Execute skill '#{skill.name}' with arguments '#{args}':\n\n#{body}"
      end

    IO.puts(Formatter.format_info("Loading and executing skill '#{skill.name}'…"))

    case Session.send_user_message(session_pid, prompt) do
      {:ok, %{content: out}} ->
        IO.puts("\n" <> Formatter.format_agent_response(out) <> "\n")
        Formatter.flush()

      {:error, err} ->
        IO.puts(Formatter.format_error(err))
        Formatter.flush()
    end
  end

  defp skill_not_found_message(skills, name) do
    case SkillManager.suggestions(skills, name) do
      [] ->
        "Skill '#{name}' not found. Use /skills to view available skills."

      [_ | _] = suggestions ->
        "Skill '#{name}' not found. Did you mean: #{Enum.join(suggestions, ", ")}?"
    end
  end

  defp handle_rules_delete do
    rules = Yoke.Rules.load_rules()

    if Enum.empty?(rules) do
      IO.puts(Formatter.format_info("No rules available to delete."))
    else
      opts =
        Enum.map(rules, fn r ->
          "[##{r["id"]}] (#{r["scope"]}): #{r["text"]}"
        end)

      ans =
        Yoke.CLI.Spinner.with_paused(fn ->
          Yoke.CLI.QuestionPrompt.ask_single_question(
            "Select rules to delete:",
            opts,
            true,
            false
          )
        end)

      case ans do
        %{selected: selected_items} when is_list(selected_items) and selected_items != [] ->
          ids =
            Enum.map(selected_items, fn item ->
              case Regex.run(~r/\[#(\d+)\]/, item) do
                [_, id_str] -> String.to_integer(id_str)
                _ -> nil
              end
            end)
            |> Enum.reject(&is_nil/1)

          Yoke.Rules.delete_rules(ids)
          IO.puts(Formatter.format_success("Deleted #{length(ids)} rule(s)."))

        _ ->
          IO.puts(Formatter.format_info("No rules deleted."))
      end
    end

    :continue
  end

  defp handle_practices_learn(args) do
    paths = String.split(args, ~r/[,;\s]+/, trim: true)

    if paths == [] do
      IO.puts(
        Formatter.format_error("Usage: /practices learn <path_to_exemplary_project1> [path2...]")
      )
    else
      langs = Yoke.Practices.detect_languages()
      lang = Enum.at(langs, 0) || "elixir"
      Yoke.Practices.squeeze_practices(lang, paths)

      IO.puts(
        Formatter.format_success(
          "Squeezed good practices for '#{lang}' from exemplary project(s)!"
        )
      )
    end

    :continue
  end

  defp handle_practices_delete do
    langs = Yoke.Practices.detect_languages()
    lang = Enum.at(langs, 0) || "elixir"
    p = Yoke.Practices.load_practices(lang)

    if Enum.empty?(p.items) do
      IO.puts(Formatter.format_info("No practice items available to delete for '#{lang}'."))
    else
      options =
        p.items
        |> Enum.with_index(1)
        |> Enum.map(fn {item, idx} -> "#{idx}. #{item}" end)

      ans =
        Yoke.CLI.Spinner.with_paused(fn ->
          Yoke.CLI.QuestionPrompt.ask_single_question(
            "Select practice items to delete for '#{lang}':",
            options,
            true,
            true
          )
        end)

      selected = Map.get(ans, :selected, [])

      if selected != [] do
        indices =
          Enum.map(selected, fn s ->
            case Regex.run(~r/^\d+/, s) do
              [num] -> String.to_integer(num)
              _ -> s
            end
          end)

        Yoke.Practices.delete_practices(lang, indices)
        IO.puts(Formatter.format_success("Deleted selected practice items for '#{lang}'."))
      else
        IO.puts(Formatter.format_info("No practice items deleted."))
      end
    end

    :continue
  end

  defp format_session_picker_label(m) do
    dt = m.updated_at |> NaiveDateTime.to_iso8601() |> String.slice(0, 19)
    name = if m[:title], do: "\"#{m.title}\"", else: "Untitled Session"
    "#{name} (#{m.session_id}) [#{m.model}, #{m.message_count} msgs, updated #{dt}]"
  end

  def print_resume_banner(session_id) do
    IO.puts("\nResume with -c (or command below):")

    IO.puts("#{Formatter.cyan()}yoke --conversation=#{session_id}#{Formatter.reset()}\n")
  end

  # ---------------------------------------------------------------------
  # Pure console mode (`!!` flip-flop)
  #
  # A stripped-down read/execute loop that never touches the Brain
  # session actor, the LLM client, or slash-command dispatch. It exists
  # so `!!` can turn `yoke` into a bare passthrough shell for a burst of
  # quick terminal commands, without the user needing to open a second
  # terminal tab/window. `!!` (typed alone) flips back to the harness
  # REPL loop, carrying the same in-memory input history forward.
  # ---------------------------------------------------------------------

  defp console_loop(session_pid, session_id, history) do
    case LineEditor.get_line(build_console_prompt(), history, %{}) do
      :eof ->
        IO.puts(Formatter.format_info("\nLeaving pure console mode -- back to Yoke."))
        loop(session_pid, session_id, history, false)

      {:error, reason} ->
        IO.puts(Formatter.format_error("Input error: #{inspect(reason)}"))
        console_loop(session_pid, session_id, history)

      line when is_binary(line) ->
        trimmed = String.trim(line)
        updated_history = if trimmed != "", do: [trimmed | history], else: history

        case trimmed do
          "" ->
            console_loop(session_pid, session_id, updated_history)

          "!!" ->
            IO.puts(Formatter.format_success("Back to Yoke -- pure console mode OFF."))
            loop(session_pid, session_id, updated_history, false)

          cmd ->
            run_console_command(cmd)
            console_loop(session_pid, session_id, updated_history)
        end
    end
  end

  def handle_review_conversation(target_id, session_pid, current_session_id) do
    clean_id =
      case target_id do
        nil ->
          current_session_id

        str when is_binary(str) ->
          s = String.trim(str)
          if s == "" or s == "current", do: current_session_id, else: s
      end

    {messages, meta} =
      if clean_id == current_session_id do
        case Session.get_messages(session_pid) do
          {:ok, msgs} ->
            stats = Session.get_stats(session_pid)
            {msgs, stats}

          _ ->
            load_session_from_store(clean_id)
        end
      else
        load_session_from_store(clean_id)
      end

    case messages do
      msgs when is_list(msgs) and msgs != [] ->
        rendered = render_conversation_review(clean_id, msgs, meta)
        IO.puts("\n" <> Formatter.format_markdown(rendered) <> "\n")

      _ ->
        IO.puts(
          Formatter.format_error(
            "Could not review conversation '#{clean_id}': conversation not found or empty."
          )
        )
    end

    :continue
  end

  defp load_session_from_store(session_id) do
    case Yoke.Brain.SessionStore.load_session(session_id) do
      {:ok, data} ->
        msgs = Map.get(data, "messages", [])
        {msgs, data}

      _ ->
        {[], %{}}
    end
  end

  defp render_conversation_review(session_id, messages, meta) do
    model = Map.get(meta, :model) || Map.get(meta, "model") || "unknown"
    msg_count = length(messages)
    step_count = Map.get(meta, :step_count) || Map.get(meta, "step_count") || 0

    header = """
    ### 󰋗 Conversation Review: `#{session_id}`
    - **Model**: `#{model}`
    - **Messages**: `#{msg_count}`
    - **Step Count**: `#{step_count}`
    """

    body =
      messages
      |> Enum.reject(fn m -> Map.get(m, "role") == "system" or Map.get(m, :role) == "system" end)
      |> Enum.with_index(1)
      |> Enum.map_join("\n\n---\n\n", fn {msg, idx} ->
        role = Map.get(msg, "role") || Map.get(msg, :role) || "unknown"
        content = Map.get(msg, "content") || Map.get(msg, :content) || ""
        tool_calls = Map.get(msg, "tool_calls") || Map.get(msg, :tool_calls)

        content_str =
          cond do
            is_binary(content) ->
              content

            is_list(content) ->
              Enum.map_join(content, "\n", fn
                %{"text" => t} -> t
                %{text: t} -> t
                other -> inspect(other)
              end)

            true ->
              inspect(content)
          end

        role_header =
          case role do
            "user" -> "#### Turn ##{idx} — 👤 User"
            "assistant" -> "#### Turn ##{idx} — 󰚩 Assistant"
            "tool" -> "#### Turn ##{idx} — 🛠 Tool Result"
            other -> "#### Turn ##{idx} — #{other}"
          end

        tc_block =
          if is_list(tool_calls) and tool_calls != [] do
            tc_items =
              Enum.map_join(tool_calls, "\n", fn tc ->
                fn_map = Map.get(tc, "function", tc)
                name = Map.get(fn_map, "name", "tool")
                args = Map.get(fn_map, "arguments", "{}")
                "- `#{name}(#{args})`"
              end)

            "\n\n**Tool Calls Executed:**\n" <> tc_items
          else
            ""
          end

        "#{role_header}\n#{content_str}#{tc_block}"
      end)

    header <> "\n\n" <> body
  end

  defp build_console_prompt do
    cwd = File.cwd!() |> Path.basename()

    "#{Formatter.yellow()}#{Formatter.bold()} console#{Formatter.reset()} " <>
      "#{Formatter.cyan()}#{cwd}#{Formatter.reset()} #{Formatter.yellow()}$#{Formatter.reset()} "
  end

  # `cd` is special-cased and applied to the running `yoke` OS process
  # itself (via `File.cd/1`), exactly like a real shell builtin -- a
  # subprocess (`sh -c "cd ..."`) can never change its parent's working
  # directory, so without this every other command would silently ignore
  # a preceding `cd`. Everything else is hosted out to `sh -c` verbatim,
  # with output streamed live to stdout as it's produced rather than
  # buffered until the command exits.
  defp run_console_command(cmd) do
    case String.split(cmd, ~r/\s+/, parts: 2) do
      ["cd"] -> console_cd(System.get_env("HOME") || "/")
      ["cd", target] -> console_cd(target)
      _ -> run_console_passthrough(cmd)
    end
  end

  defp console_cd(target) do
    expanded = Path.expand(target, File.cwd!())

    case File.cd(expanded) do
      :ok ->
        :ok

      {:error, reason} ->
        IO.puts(Formatter.format_error("cd: #{expanded}: #{:file.format_error(reason)}"))
    end
  end

  defp run_console_passthrough(cmd) do
    case System.cmd("sh", ["-c", cmd],
           stderr_to_stdout: true,
           into: IO.stream(:stdio, :line)
         ) do
      {_stream, 0} ->
        :ok

      {_stream, code} ->
        IO.puts(Formatter.format_error("[exit code #{code}]"))
    end
  rescue
    e -> IO.puts(Formatter.format_error("Command failed: #{Exception.message(e)}"))
  end

  defp handle_paste_clipboard_image(session_pid, session_id) do
    case Yoke.Clipboard.fetch_image() do
      {:ok, mime, bytes} ->
        ext =
          case mime do
            "image/jpeg" -> ".jpg"
            "image/webp" -> ".webp"
            "image/gif" -> ".gif"
            _ -> ".png"
          end

        dir = Path.join(File.cwd!(), ".yoke/sessions/assets")
        File.mkdir_p!(dir)

        timestamp = System.system_time(:millisecond)
        filename = "clipboard_#{timestamp}#{ext}"
        filepath = Path.join(dir, filename)
        File.write!(filepath, bytes)

        ref_path = Path.join(".yoke/sessions/assets", filename)
        prompt = "Analyze pasted clipboard image: @#{ref_path}"
        IO.puts(Formatter.format_info("Pasted clipboard image saved to '#{ref_path}'"))
        handle_input(prompt, session_pid, session_id)

      {:error, reason} ->
        IO.puts(Formatter.format_error("Failed to read image from clipboard: #{reason}"))
        :continue
    end
  end
end
