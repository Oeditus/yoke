defmodule Yoke.CLI.ConfigExplorer do
  @moduledoc """
  Full-Screen Interactive TUI Explorer for navigating, inspecting, expanding,
  and editing the `.yoke` configuration ecosystem (.yoke/config.json, rules.json,
  practices/, sessions/, jobs/, skills/, review_patterns.md, bash_analytics.json,
  and ERRORS_TO_FIX.lmml).

  Features:
  - Full-screen alternate buffer rendering with dynamic column/row viewport resizing
  - Color-themed tab bar per category (Settings, Rules, Conversations, Practices, Jobs, Skills, Diagnostics, Analytics)
  - Rich conversation/session decoder displaying models, message counts, sizes, and previews
  - Expandable Detail View modal (Enter key) for deep inspection of full transcripts, logs, and tracebacks
  - Full line-tolerance and ANSI-aware string truncation and scrolling
  - Editing, toggling, and deleting of rules, configs, skills, jobs, and session files
  """
  alias Yoke.BashTracker
  alias Yoke.Brain.SessionLmml
  alias Yoke.CLI.Formatter
  alias Yoke.CLI.LineEditor
  alias Yoke.CLI.TerminalOwner
  alias Yoke.Config
  alias Yoke.PRReview.Patterns, as: ReviewPatterns
  alias Yoke.Rules
  alias Yoke.Skill.Manager, as: SkillManager
  alias Yoke.TaskEngine.JobManager

  @tabs [:settings, :rules, :sessions, :practices, :jobs, :skills, :diagnostics, :analytics]

  @doc "Main entry point to launch the Config Explorer TUI."
  def run(opts \\ []) do
    cwd = Keyword.get(opts, :cwd, File.cwd!())

    if tty?() do
      run_tty(cwd, opts)
    else
      run_non_tty(cwd, opts)
    end
  end

  # ---------------------------------------------------------------------
  # Data Loading & Scanning
  # ---------------------------------------------------------------------

  @doc "Scans local and global .yoke directory tree and returns structured summary map."
  def scan_directory_tree(cwd \\ ".") do
    local_dir = Path.join(cwd, ".yoke")
    global_dir = Path.expand("~/.yoke")

    config = Config.load_config(cwd)
    rules = Rules.load_rules(cwd)
    sessions = list_session_files(cwd)
    practices = list_practice_files(cwd)
    jobs = list_job_files(cwd)
    skills = list_skill_files(cwd)
    errors = read_error_log(cwd)
    patterns = list_review_patterns(cwd)
    analytics = read_bash_analytics(cwd)

    %{
      local_dir: local_dir,
      global_dir: global_dir,
      config: config,
      rules: rules,
      sessions: sessions,
      practices: practices,
      jobs: jobs,
      skills: skills,
      errors: errors,
      patterns: patterns,
      analytics: analytics
    }
  end

  def list_session_files(cwd \\ ".") do
    dirs = [
      Path.join(cwd, ".yoke/sessions"),
      Path.expand("~/.yoke/sessions")
    ]

    dirs
    |> Enum.flat_map(fn dir ->
      if File.dir?(dir) do
        case File.ls(dir) do
          {:ok, files} ->
            files
            |> Enum.filter(&(String.ends_with?(&1, ".lmml") or String.ends_with?(&1, ".lmmlz")))
            |> Enum.flat_map(fn file ->
              full_path = Path.join(dir, file)

              case File.stat(full_path) do
                {:ok, stat} ->
                  id = String.replace(file, ~r/\.(lmml|lmmlz)$/, "")
                  meta = parse_session_metadata(full_path)

                  [
                    Map.merge(meta, %{
                      id: id,
                      file: file,
                      path: full_path,
                      size: stat.size,
                      mtime: stat.mtime,
                      timestamp: format_timestamp(stat.mtime)
                    })
                  ]

                _ ->
                  []
              end
            end)

          _ ->
            []
        end
      else
        []
      end
    end)
    |> Enum.uniq_by(& &1.path)
    |> Enum.sort_by(& &1.mtime, :desc)
  end

  def parse_session_metadata(path) do
    if File.exists?(path) and String.ends_with?(path, ".lmml") do
      case File.read(path) do
        {:ok, content} ->
          model =
            case Regex.run(~r/"model"\s*:\s*"([^"]+)"/, content) do
              [_, m] -> m
              _ -> "deepseek-chat"
            end

          msg_count = Regex.scan(~r/^# (User|Assistant|Tool Call)/m, content) |> length()

          preview =
            case Regex.run(~r/# User\s+([^\r\n#]+)/m, content) do
              [_, p] ->
                String.trim(p)

              _ ->
                case SessionLmml.decode(content) do
                  {:ok, data} when is_map(data) ->
                    msgs = Map.get(data, "messages") || Map.get(data, :messages) || []

                    user_msg =
                      Enum.find(msgs, fn m ->
                        to_string(Map.get(m, "role") || Map.get(m, :role)) == "user"
                      end)

                    if user_msg do
                      cnt =
                        Map.get(user_msg, "content") || Map.get(user_msg, :content) ||
                          Map.get(user_msg, "text")

                      to_string(cnt || "") |> String.replace(~r/[\r\n\t]+/, " ") |> String.trim()
                    else
                      "(session narrative)"
                    end

                  _ ->
                    "(session narrative)"
                end
            end

          %{model: model, msg_count: max(msg_count, 1), preview: preview}

        _ ->
          %{model: "unknown", msg_count: 0, preview: "(unreadable)"}
      end
    else
      %{model: "lmmlz", msg_count: 0, preview: "(compressed session container)"}
    end
  end

  def list_practice_files(cwd \\ ".") do
    local_dir = Path.join(cwd, ".yoke/practices")
    global_dir = Path.expand("~/.yoke/practices")

    local_files =
      if File.dir?(local_dir),
        do: File.ls!(local_dir) |> Enum.map(&{:local, &1, Path.join(local_dir, &1)}),
        else: []

    global_files =
      if File.dir?(global_dir),
        do: File.ls!(global_dir) |> Enum.map(&{:global, &1, Path.join(global_dir, &1)}),
        else: []

    (local_files ++ global_files)
    |> Enum.filter(fn {_scope, f, _path} -> String.ends_with?(f, ".lmml") end)
    |> Enum.map(fn {scope, file, path} ->
      lang = String.replace(file, ".lmml", "")

      size =
        case File.stat(path) do
          {:ok, st} -> st.size
          _ -> 0
        end

      %{scope: scope, lang: lang, file: file, path: path, size: size}
    end)
  end

  def list_job_files(cwd \\ ".") do
    dir = Path.join(cwd, ".yoke/jobs")

    active_map =
      try do
        if Process.whereis(JobManager) do
          JobManager.list_jobs()
          |> Map.new(fn job -> {job.id, job} end)
        else
          %{}
        end
      rescue
        _ -> %{}
      end

    file_jobs =
      if File.dir?(dir) do
        case File.ls(dir) do
          {:ok, files} ->
            files
            |> Enum.filter(&String.ends_with?(&1, ".log"))
            |> Enum.flat_map(fn file ->
              full_path = Path.join(dir, file)

              case File.stat(full_path) do
                {:ok, stat} ->
                  id = String.replace(file, ".log", "")
                  active_info = Map.get(active_map, id)
                  status = if active_info, do: active_info.status, else: :completed
                  cmd = if active_info, do: active_info.command, else: nil

                  [
                    %{
                      id: id,
                      file: file,
                      path: full_path,
                      size: stat.size,
                      mtime: stat.mtime,
                      timestamp: format_timestamp(stat.mtime),
                      status: status,
                      command: cmd
                    }
                  ]

                _ ->
                  []
              end
            end)

          _ ->
            []
        end
      else
        []
      end

    existing_ids = MapSet.new(file_jobs, & &1.id)

    in_memory_jobs =
      active_map
      |> Map.values()
      |> Enum.reject(&MapSet.member?(existing_ids, &1.id))
      |> Enum.map(fn job ->
        log_path = Path.join(dir, "#{job.id}.log")

        size =
          case File.stat(log_path) do
            {:ok, st} -> st.size
            _ -> 0
          end

        %{
          id: job.id,
          file: "#{job.id}.log",
          path: log_path,
          size: size,
          mtime: {{1970, 1, 1}, {0, 0, 0}},
          timestamp: "active",
          status: job.status,
          command: job.command
        }
      end)

    (file_jobs ++ in_memory_jobs)
    |> Enum.sort_by(& &1.mtime, :desc)
  end

  def list_skill_files(cwd \\ ".") do
    SkillManager.discover_skills(cwd: cwd)
  rescue
    _ -> []
  end

  def read_bash_analytics(cwd \\ ".") do
    BashTracker.stats(cwd: cwd)
  rescue
    _ ->
      %{
        total_calls: 0,
        unique_commands: 0,
        ineffective_calls: 0,
        ineffective_percentage: 0.0,
        root_commands: [],
        top_ineffective: [],
        recent_calls: []
      }
  end

  def list_review_patterns(cwd \\ ".") do
    ReviewPatterns.load_patterns(cwd)
  rescue
    _ -> []
  end

  def read_error_log(cwd \\ ".") do
    file_path = Path.join(cwd, ".yoke/ERRORS_TO_FIX.lmml")

    if File.exists?(file_path) do
      stat = File.stat!(file_path)

      content =
        case File.read(file_path) do
          {:ok, binary} -> Formatter.sanitize_utf8(binary)
          _ -> ""
        end

      raw_entries =
        content
        |> String.split("<!-- error_entry -->", trim: true)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))

      parsed_entries =
        raw_entries
        |> Enum.map(fn entry ->
          ts_str =
            case Regex.run(~r/\[(\d{4}-\d{2}-\d{2}[T\s]\d{2}:\d{2}:\d{2}[^\]]*)\]/, entry) do
              [_, ts] -> format_timestamp(ts)
              _ -> format_timestamp(stat.mtime)
            end

          lines =
            entry
            |> String.split("\n")
            |> Enum.map(&String.trim/1)
            |> Enum.reject(fn l ->
              l == "" or
                String.starts_with?(l, "```") or
                String.starts_with?(l, "<!--")
            end)
            |> Enum.map(fn l ->
              if String.starts_with?(l, "##") do
                l
                |> String.replace(
                  ~r/^##\s*(\[\d{4}-\d{2}-\d{2}[^\]]*\]\s*)?(Level:\s*\w+\s*)?/,
                  ""
                )
                |> String.trim()
              else
                l
              end
            end)
            |> Enum.reject(&(&1 == ""))

          first_line = List.first(lines) || entry

          reason_line =
            Enum.find(lines, fn l ->
              String.contains?(l, "Reason:") or String.contains?(l, "ArgumentError") or
                String.contains?(l, "RuntimeError") or String.contains?(l, "MatchError")
            end)

          title =
            if reason_line != nil and reason_line != first_line do
              cleaned_reason =
                reason_line
                |> String.replace(~r/^[●•\s]+/, "")
                |> String.replace(~r/^\x1b\[[0-9;]*m/, "")

              cleaned_first =
                first_line
                |> String.replace(~r/^[●•\s]+/, "")
                |> String.replace(~r/^\x1b\[[0-9;]*m/, "")
                |> String.trim_trailing(":")

              "#{cleaned_first} (#{cleaned_reason})"
            else
              first_line
              |> String.replace(~r/^[●•\s]+/, "")
              |> String.replace(~r/^\x1b\[[0-9;]*m/, "")
            end

          %{
            timestamp: ts_str,
            title: title,
            raw_entry: entry
          }
        end)
        |> Enum.sort_by(& &1.timestamp, :desc)

      %{
        file_path: file_path,
        count: length(parsed_entries),
        content: content,
        entries: parsed_entries
      }
    else
      %{file_path: file_path, count: 0, content: "", entries: []}
    end
  end

  def format_timestamp({{y, m, d}, {h, i, s}}) do
    y_s = String.pad_leading(to_string(y), 4, "0")
    m_s = String.pad_leading(to_string(m), 2, "0")
    d_s = String.pad_leading(to_string(d), 2, "0")
    h_s = String.pad_leading(to_string(h), 2, "0")
    i_s = String.pad_leading(to_string(i), 2, "0")
    s_s = String.pad_leading(to_string(s), 2, "0")
    "#{y_s}-#{m_s}-#{d_s} #{h_s}:#{i_s}:#{s_s}"
  end

  def format_timestamp(%DateTime{} = dt) do
    Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")
  end

  def format_timestamp(ts) when is_binary(ts) do
    ts
    |> String.replace("T", " ")
    |> String.replace("Z", "")
    |> String.slice(0, 19)
  end

  def format_timestamp(_), do: "unknown"

  # ---------------------------------------------------------------------
  # TUI State Management
  # ---------------------------------------------------------------------

  def new_state(cwd) do
    tree = scan_directory_tree(cwd)

    %{
      cwd: cwd,
      active_tab: :settings,
      tab_index: 0,
      tree: tree,
      cursor: 0,
      view_mode: :list,
      detail_scroll: 0,
      status_notice: nil
    }
  end

  def switch_tab(state, delta) do
    new_idx = Integer.mod(state.tab_index + delta, length(@tabs))
    new_tab = Enum.at(@tabs, new_idx)

    %{
      state
      | tab_index: new_idx,
        active_tab: new_tab,
        cursor: 0,
        view_mode: :list,
        detail_scroll: 0,
        status_notice: nil
    }
  end

  def move_cursor(%{view_mode: :detail} = state, delta) do
    new_scroll = max(0, state.detail_scroll + delta)
    %{state | detail_scroll: new_scroll}
  end

  def move_cursor(state, delta) do
    max_idx = max(0, item_count(state) - 1)
    new_cursor = Integer.mod(state.cursor + delta, max(1, max_idx + 1))
    %{state | cursor: new_cursor}
  end

  def item_count(%{active_tab: :settings, tree: tree}), do: map_size(tree.config)
  def item_count(%{active_tab: :rules, tree: tree}), do: length(tree.rules)
  def item_count(%{active_tab: :sessions, tree: tree}), do: length(tree.sessions)
  def item_count(%{active_tab: :practices, tree: tree}), do: length(tree.practices)
  def item_count(%{active_tab: :jobs, tree: tree}), do: length(tree.jobs)
  def item_count(%{active_tab: :skills, tree: tree}), do: length(tree.skills)
  def item_count(%{active_tab: :diagnostics, tree: tree}), do: length(tree.errors.entries)
  def item_count(%{active_tab: :analytics} = state), do: length(fetch_tab_items(state))
  def item_count(_), do: 0

  # ---------------------------------------------------------------------
  # Interactive Operations (Expand, Toggle, Edit, Delete, Add)
  # ---------------------------------------------------------------------

  def handle_select(state) do
    case state.view_mode do
      :list ->
        case state.active_tab do
          :settings ->
            keys = Enum.sort(Map.keys(state.tree.config))

            if key = Enum.at(keys, state.cursor) do
              val = Map.get(state.tree.config, key)

              if is_boolean(val) do
                handle_toggle(state)
              else
                %{state | view_mode: :detail, detail_scroll: 0}
              end
            else
              state
            end

          _ ->
            %{state | view_mode: :detail, detail_scroll: 0}
        end

      :detail ->
        %{state | view_mode: :list, detail_scroll: 0}
    end
  end

  def handle_toggle(state) do
    case state.active_tab do
      :settings ->
        config_keys = Enum.sort(Map.keys(state.tree.config))

        if key = Enum.at(config_keys, state.cursor) do
          val = Map.get(state.tree.config, key)

          if is_boolean(val) do
            updated_config = Map.put(state.tree.config, key, not val)
            Config.save_config(updated_config, state.cwd)
            refresh_state(state, "Toggled setting '#{key}' -> #{not val}")
          else
            %{state | view_mode: :detail, detail_scroll: 0}
          end
        else
          state
        end

      :rules ->
        if rule = Enum.at(state.tree.rules, state.cursor) do
          rule_id = Map.get(rule, "id")
          {:ok, _} = Rules.toggle_rule(rule_id, state.cwd)
          refresh_state(state, "Toggled rule ##{rule_id}")
        else
          state
        end

      _ ->
        state
    end
  end

  def handle_edit(state) do
    case state.active_tab do
      :settings ->
        config_keys = Enum.sort(Map.keys(state.tree.config))

        if key = Enum.at(config_keys, state.cursor) do
          curr_val = Map.get(state.tree.config, key)
          prompt_and_update_setting(state, key, curr_val)
        else
          state
        end

      :rules ->
        if rule = Enum.at(state.tree.rules, state.cursor) do
          id = Map.get(rule, "id")
          curr_text = Map.get(rule, "text", "")
          prompt_and_update_rule(state, id, curr_text)
        else
          state
        end

      :practices ->
        if prac = Enum.at(state.tree.practices, state.cursor) do
          if File.exists?(prac.path) do
            Yoke.CLI.Editor.edit_file(prac.path,
              on_before: &restore_tty_mode/0,
              on_after: &set_raw_mode/0
            )

            refresh_state(state, "Edited practice file '#{prac.file}'")
          else
            state
          end
        else
          state
        end

      :sessions ->
        if sess = Enum.at(state.tree.sessions, state.cursor) do
          if File.exists?(sess.path) do
            Yoke.CLI.Editor.edit_file(sess.path,
              on_before: &restore_tty_mode/0,
              on_after: &set_raw_mode/0
            )

            refresh_state(state, "Opened session log '#{sess.file}' in editor.")
          else
            state
          end
        else
          state
        end

      :jobs ->
        if job = Enum.at(state.tree.jobs, state.cursor) do
          if File.exists?(job.path) do
            Yoke.CLI.Editor.edit_file(job.path,
              on_before: &restore_tty_mode/0,
              on_after: &set_raw_mode/0
            )

            refresh_state(state, "Opened job log '#{job.file}' in editor.")
          else
            state
          end
        else
          state
        end

      :skills ->
        if skill = Enum.at(state.tree.skills, state.cursor) do
          if skill.path && File.exists?(skill.path) do
            Yoke.CLI.Editor.edit_file(skill.path,
              on_before: &restore_tty_mode/0,
              on_after: &set_raw_mode/0
            )

            refresh_state(state, "Opened skill '#{skill.name}' in editor.")
          else
            state
          end
        else
          state
        end

      :diagnostics ->
        if File.exists?(state.tree.errors.file_path) do
          Yoke.CLI.Editor.edit_file(state.tree.errors.file_path,
            on_before: &restore_tty_mode/0,
            on_after: &set_raw_mode/0
          )

          refresh_state(state, "Opened diagnostic log ERRORS_TO_FIX.lmml in editor.")
        else
          state
        end

      :analytics ->
        items = fetch_tab_items(state)

        if item = Enum.at(items, state.cursor) do
          target_file =
            case item.kind do
              :pattern ->
                ReviewPatterns.ensure_patterns_file(state.cwd)

              _ ->
                Path.join(state.cwd, ".yoke/bash_analytics.json")
            end

          if File.exists?(target_file) do
            Yoke.CLI.Editor.edit_file(target_file,
              on_before: &restore_tty_mode/0,
              on_after: &set_raw_mode/0
            )

            refresh_state(state, "Opened #{Path.basename(target_file)} in editor.")
          else
            state
          end
        else
          state
        end

      _ ->
        state
    end
  end

  def handle_delete(state) do
    case state.active_tab do
      :rules ->
        if rule = Enum.at(state.tree.rules, state.cursor) do
          rule_id = Map.get(rule, "id")
          {:ok, _} = Rules.delete_rules([rule_id], state.cwd)
          refresh_state(state, "Deleted rule ##{rule_id}")
        else
          state
        end

      :sessions ->
        if sess = Enum.at(state.tree.sessions, state.cursor) do
          File.rm(sess.path)
          refresh_state(state, "Deleted session file '#{sess.file}'")
        else
          state
        end

      :jobs ->
        if job = Enum.at(state.tree.jobs, state.cursor) do
          if File.exists?(job.path) do
            File.rm(job.path)
            refresh_state(state, "Deleted job log '#{job.file}'")
          else
            state
          end
        else
          state
        end

      :skills ->
        if skill = Enum.at(state.tree.skills, state.cursor) do
          if (skill.scope == :project and skill.path) && File.exists?(skill.path) do
            dir = Path.dirname(skill.path)

            if Path.basename(dir) == skill.name do
              File.rm_rf(dir)
            else
              File.rm(skill.path)
            end

            refresh_state(state, "Deleted project skill '#{skill.name}'")
          else
            %{state | status_notice: "Cannot delete non-project skill '#{skill.name}'"}
          end
        else
          state
        end

      :diagnostics ->
        if File.exists?(state.tree.errors.file_path) do
          File.write!(state.tree.errors.file_path, "")
          refresh_state(state, "Cleared diagnostic log ERRORS_TO_FIX.lmml")
        else
          state
        end

      :analytics ->
        items = fetch_tab_items(state)

        if item = Enum.at(items, state.cursor) do
          case item.kind do
            k when k in [:bash_summary, :bash_ineffective, :bash_root] ->
              BashTracker.clear(cwd: state.cwd)
              refresh_state(state, "Cleared bash command analytics.")

            _ ->
              state
          end
        else
          state
        end

      _ ->
        state
    end
  end

  def handle_add_rule(state) do
    input =
      case Yoke.CLI.Editor.edit_text("",
             on_before: &restore_tty_mode/0,
             on_after: &set_raw_mode/0
           ) do
        {:ok, text} ->
          text

        {:fallback, _} ->
          restore_tty_mode()

          IO.write(
            :user,
            "\r\n#{Formatter.cyan()}󰏫  Enter new rule (format 'scope: text' or 'text'): #{Formatter.reset()}"
          )

          result =
            case IO.gets(:user, "") do
              s when is_binary(s) -> String.trim(s)
              _ -> ""
            end

          set_raw_mode()
          result

        _ ->
          ""
      end

    if input != "" do
      Rules.add_rule(input, state.cwd)
      refresh_state(state, "Added new rule.")
    else
      state
    end
  end

  defp prompt_and_update_setting(state, key, curr_val) do
    val_str = if is_binary(curr_val), do: curr_val, else: inspect(curr_val)

    input =
      case Yoke.CLI.Editor.edit_text(val_str,
             on_before: &restore_tty_mode/0,
             on_after: &set_raw_mode/0
           ) do
        {:ok, text} ->
          text

        {:fallback, _} ->
          restore_tty_mode()
          val_type = if is_integer(curr_val), do: "integer", else: "string"

          IO.write(
            :user,
            "\r\n#{Formatter.cyan()}󰏫  Edit setting '#{key}' (#{val_type}, current: #{inspect(curr_val)}): #{Formatter.reset()}"
          )

          result =
            case IO.gets(:user, "") do
              s when is_binary(s) -> String.trim(s)
              _ -> ""
            end

          set_raw_mode()
          result

        _ ->
          ""
      end

    if input != "" do
      new_val =
        cond do
          is_integer(curr_val) ->
            case Integer.parse(input) do
              {n, _} -> n
              _ -> curr_val
            end

          is_float(curr_val) ->
            case Float.parse(input) do
              {f, _} -> f
              _ -> curr_val
            end

          is_boolean(curr_val) ->
            input in ["true", "1", "yes"]

          true ->
            input
        end

      updated_config = Map.put(state.tree.config, key, new_val)
      Config.save_config(updated_config, state.cwd)
      refresh_state(state, "Updated '#{key}' -> #{inspect(new_val)}")
    else
      state
    end
  end

  defp prompt_and_update_rule(state, rule_id, curr_text) do
    input =
      case Yoke.CLI.Editor.edit_text(curr_text,
             on_before: &restore_tty_mode/0,
             on_after: &set_raw_mode/0
           ) do
        {:ok, text} ->
          text

        {:fallback, _} ->
          restore_tty_mode()

          IO.write(
            :user,
            "\r\n#{Formatter.cyan()}󰏫  Edit rule ##{rule_id} text (current: #{curr_text}): #{Formatter.reset()}"
          )

          result =
            case IO.gets(:user, "") do
              s when is_binary(s) -> String.trim(s)
              _ -> ""
            end

          set_raw_mode()
          result

        _ ->
          ""
      end

    if input != "" do
      rules = Rules.load_rules(state.cwd)

      updated =
        Enum.map(rules, fn r ->
          if Map.get(r, "id") == rule_id do
            Map.put(r, "text", input)
          else
            r
          end
        end)

      Rules.save_rules(updated, state.cwd)
      refresh_state(state, "Updated rule ##{rule_id}")
    else
      state
    end
  end

  def refresh_state(state, notice \\ nil) do
    updated_tree = scan_directory_tree(state.cwd)
    %{state | tree: updated_tree, status_notice: notice}
  end

  def display_width(str) when is_binary(str), do: Formatter.display_width(str)
  def display_width(_), do: 0

  def tab_label(:settings), do: "Settings"
  def tab_label(:rules), do: "Rules"
  def tab_label(:sessions), do: "Conversations"
  def tab_label(:practices), do: "Practices"
  def tab_label(:jobs), do: "Jobs"
  def tab_label(:skills), do: "Skills"
  def tab_label(:diagnostics), do: "Diagnostics"
  def tab_label(:analytics), do: "Analytics"
  def tab_label(_), do: "Unknown"

  # ---------------------------------------------------------------------
  # Full-Screen Viewport Rendering Engine
  # ---------------------------------------------------------------------

  def render_full_screen(state) do
    {cols, rows} = terminal_dimensions()

    theme = tab_theme(state.active_tab)

    # 1. Header Box
    header_title = " ⚙ .yoke Config Directory Explorer "
    header_fill = String.duplicate("─", max(0, cols - 3 - display_width(header_title)))

    header_line =
      "#{theme.border}╭─#{theme.header_title}#{header_title}#{Formatter.reset()}#{theme.border}#{header_fill}╮#{Formatter.reset()}"

    # 2. Tab Bar Line
    tabs_rendered =
      @tabs
      |> Enum.with_index()
      |> Enum.map_join(" ", fn {tab, idx} ->
        t_theme = tab_theme(tab)
        label = tab_label(tab)

        if idx == state.tab_index do
          "#{t_theme.pill_bg} #{idx + 1}: #{label} #{Formatter.reset()}"
        else
          "#{Formatter.dim()}[#{idx + 1}: #{label}]#{Formatter.reset()}"
        end
      end)

    tab_line = format_box_row(" #{tabs_rendered}", cols, theme.border)

    # 3. Divider Line
    div_fill = String.duplicate("─", max(0, cols - 2))
    div_line = "#{theme.border}├#{div_fill}┤#{Formatter.reset()}"

    # 4. Viewport Content (List View or Expand/Detail View)
    viewport_rows = max(5, rows - 6)

    content_lines =
      case state.view_mode do
        :list -> render_list_viewport(state, cols, viewport_rows, theme)
        :detail -> render_detail_viewport(state, cols, viewport_rows, theme)
      end

    # 5. Status Notice Line or Divider
    notice_str =
      if state.status_notice do
        " #{Formatter.yellow()}⚡ Notice: #{state.status_notice}#{Formatter.reset()}"
      else
        " #{Formatter.dim()}Path: #{state.cwd}/.yoke | Active tab: #{tab_label(state.active_tab)}#{Formatter.reset()}"
      end

    info_line = format_box_row(notice_str, cols, theme.border)

    # 6. Controls Footer Line
    footer_text =
      case state.view_mode do
        :list ->
          "[Tab/1-8: Tab | ↑/↓: Select | Enter: Expand/Detail | Space: Toggle | a: Add Rule | d: Delete | r: Refresh | q: Exit]"

        :detail ->
          "[↑/↓/PgUp/PgDn: Scroll Detail | e: Edit | Space: Toggle | Esc/q: Back to List View]"
      end

    footer_fill = String.duplicate("─", max(0, cols - 3 - display_width(footer_text)))

    footer_line =
      "#{theme.border}╰─#{Formatter.dim()}#{footer_text}#{Formatter.reset()}#{theme.border}#{footer_fill}╯#{Formatter.reset()}"

    full_output =
      [header_line, tab_line, div_line] ++
        content_lines ++
        [div_line, info_line, footer_line]

    IO.write(:user, Enum.join(full_output, "\r\n"))
    state
  end

  defp format_box_row(content_str, total_cols, border_ansi) do
    safe_content = Formatter.sanitize_utf8(content_str)
    content_width = max(1, total_cols - 4)
    truncated = truncate_ansi_line(safe_content, content_width)
    vis_len = display_width(truncated)
    padding = String.duplicate(" ", max(0, content_width - vis_len))

    "#{border_ansi}│#{Formatter.reset()} #{truncated}#{padding} #{border_ansi}│#{Formatter.reset()}"
  end

  defp truncate_ansi_line(str, max_width) do
    safe_str = Formatter.sanitize_utf8(str)

    if display_width(safe_str) <= max_width do
      safe_str
    else
      LineEditor.truncate_to_width(safe_str, max_width)
    end
  end

  # ---------------------------------------------------------------------
  # List Viewport Renderer
  # ---------------------------------------------------------------------

  defp render_list_viewport(state, cols, height, theme) do
    items = fetch_tab_items(state)

    if items == [] do
      empty_msg = "  (No items found in this section)"

      [format_box_row(empty_msg, cols, theme.border)] ++
        pad_empty_rows(height - 1, cols, theme.border)
    else
      total_items = length(items)
      cursor = min(state.cursor, total_items - 1)

      # Viewport scroll window calculation
      start_idx =
        cond do
          cursor < height -> 0
          cursor >= total_items - height -> max(0, total_items - height)
          true -> cursor - div(height, 2)
        end

      visible_items = Enum.slice(items, start_idx, height)

      rows =
        visible_items
        |> Enum.with_index(start_idx)
        |> Enum.map(fn {item, idx} ->
          is_selected = idx == cursor
          format_item_row(state.active_tab, item, is_selected, cols, theme)
        end)

      remaining = height - length(rows)
      rows ++ pad_empty_rows(remaining, cols, theme.border)
    end
  end

  defp pad_empty_rows(count, cols, border_ansi) when count > 0 do
    Enum.map(1..count, fn _ -> format_box_row("", cols, border_ansi) end)
  end

  defp pad_empty_rows(_, _, _), do: []

  defp fetch_tab_items(%{active_tab: :settings, tree: tree}) do
    tree.config |> Map.keys() |> Enum.sort() |> Enum.map(fn k -> {k, Map.get(tree.config, k)} end)
  end

  defp fetch_tab_items(%{active_tab: :rules, tree: tree}), do: tree.rules
  defp fetch_tab_items(%{active_tab: :sessions, tree: tree}), do: tree.sessions
  defp fetch_tab_items(%{active_tab: :practices, tree: tree}), do: tree.practices
  defp fetch_tab_items(%{active_tab: :jobs, tree: tree}), do: tree.jobs
  defp fetch_tab_items(%{active_tab: :skills, tree: tree}), do: tree.skills
  defp fetch_tab_items(%{active_tab: :diagnostics, tree: tree}), do: tree.errors.entries

  defp fetch_tab_items(%{active_tab: :analytics, tree: tree}) do
    stats = tree.analytics || %{}

    summary_item = %{
      kind: :bash_summary,
      total_calls: Map.get(stats, :total_calls, 0),
      ineffective_calls: Map.get(stats, :ineffective_calls, 0),
      ineffective_percentage: Map.get(stats, :ineffective_percentage, 0.0),
      unique_commands: Map.get(stats, :unique_commands, 0)
    }

    ineffective_items =
      Map.get(stats, :top_ineffective, [])
      |> Enum.map(fn entry ->
        %{
          kind: :bash_ineffective,
          entry: entry
        }
      end)

    root_items =
      Map.get(stats, :root_commands, [])
      |> Enum.map(fn
        entry when is_map(entry) ->
          %{
            kind: :bash_root,
            cmd: entry["name"] || entry[:name] || entry["command"] || "",
            count: entry["count"] || entry[:count] || 0,
            freq: entry["frequency"] || entry[:frequency] || 0.0
          }

        {cmd, count, freq} ->
          %{
            kind: :bash_root,
            cmd: cmd,
            count: count,
            freq: freq
          }

        _ ->
          nil
      end)
      |> Enum.reject(&is_nil/1)

    pattern_items =
      (tree.patterns || [])
      |> Enum.map(fn pat ->
        %{
          kind: :pattern,
          pattern: pat
        }
      end)

    [summary_item] ++ ineffective_items ++ root_items ++ pattern_items
  end

  defp format_item_row(:settings, {key, val}, is_selected, cols, theme) do
    type_tag =
      cond do
        is_boolean(val) -> "[bool]"
        is_integer(val) -> "[num]"
        is_binary(val) -> "[str]"
        true -> "[val]"
      end

    val_str = inspect(val)

    content =
      if is_selected do
        "#{theme.bold_cursor} ❯ #{key} #{Formatter.dim()}#{type_tag}:#{Formatter.reset()} #{theme.bold_cursor}#{val_str}#{Formatter.reset()}"
      else
        "   #{key} #{Formatter.dim()}#{type_tag}: #{val_str}#{Formatter.reset()}"
      end

    format_box_row(content, cols, theme.border)
  end

  defp format_item_row(:rules, rule, is_selected, cols, theme) do
    id = Map.get(rule, "id")
    scope = Map.get(rule, "scope", "all")
    text = Map.get(rule, "text", "")
    enabled? = Map.get(rule, "enabled", true)

    status_mark =
      if enabled?,
        do: "#{Formatter.green()}✔ enabled#{Formatter.reset()}",
        else: "#{Formatter.red()}✘ disabled#{Formatter.reset()}"

    content =
      if is_selected do
        "#{theme.bold_cursor} ❯ [##{id} scope:#{scope}] #{status_mark} #{Formatter.bold()}#{text}#{Formatter.reset()}"
      else
        "   [##{id} scope:#{scope}] #{status_mark} #{text}"
      end

    format_box_row(content, cols, theme.border)
  end

  defp format_item_row(:sessions, sess, is_selected, cols, theme) do
    size_kb = Float.round(sess.size / 1024, 1)
    model = Map.get(sess, :model, "deepseek-chat")
    msg_cnt = Map.get(sess, :msg_count, 0)
    preview = Map.get(sess, :preview, "")
    ts = Map.get(sess, :timestamp, "")

    content =
      if is_selected do
        "#{theme.bold_cursor} ❯ #{sess.id} #{Formatter.reset()}#{Formatter.yellow()}[#{ts}]#{Formatter.reset()} #{Formatter.cyan()}[#{model}] #{msg_cnt} msgs (#{size_kb} KB) - \"#{preview}\"#{Formatter.reset()}"
      else
        "   #{sess.id} #{Formatter.dim()}[#{ts}] [#{model}] #{msg_cnt} msgs (#{size_kb} KB) - \"#{preview}\"#{Formatter.reset()}"
      end

    format_box_row(content, cols, theme.border)
  end

  defp format_item_row(:practices, prac, is_selected, cols, theme) do
    content =
      if is_selected do
        "#{theme.bold_cursor} ❯ [#{prac.scope}] Language: #{prac.lang} - #{prac.file} (#{prac.size} bytes)#{Formatter.reset()}"
      else
        "   [#{prac.scope}] Language: #{prac.lang} - #{prac.file} (#{prac.size} bytes)"
      end

    format_box_row(content, cols, theme.border)
  end

  defp format_item_row(:jobs, job, is_selected, cols, theme) do
    ts = Map.get(job, :timestamp, "")

    status_tag =
      case Map.get(job, :status) do
        :running -> "#{Formatter.green()}● running#{Formatter.reset()}"
        {:exited, 0} -> "#{Formatter.dim()}✔ done#{Formatter.reset()}"
        {:exited, code} -> "#{Formatter.red()}✘ code(#{code})#{Formatter.reset()}"
        {:failed, _} -> "#{Formatter.red()}✘ failed#{Formatter.reset()}"
        _ -> "#{Formatter.dim()}✔ log#{Formatter.reset()}"
      end

    cmd_part =
      if job[:command] do
        " - \"#{job[:command]}\""
      else
        ""
      end

    content =
      if is_selected do
        "#{theme.bold_cursor} ❯ Job #{job.id} [#{status_tag}#{theme.bold_cursor}] #{Formatter.yellow()}[#{ts}]#{Formatter.reset()} #{theme.bold_cursor}(#{job.size}B)#{Formatter.reset()}#{cmd_part}"
      else
        "   Job #{job.id} [#{status_tag}] #{Formatter.dim()}[#{ts}] (#{job.size}B)#{Formatter.reset()}#{cmd_part}"
      end

    format_box_row(content, cols, theme.border)
  end

  defp format_item_row(:skills, skill, is_selected, cols, theme) do
    scope_tag =
      case skill.scope do
        :project -> "#{Formatter.cyan()}[project]#{Formatter.reset()}"
        :global -> "#{Formatter.yellow()}[global]#{Formatter.reset()}"
        :builtin -> "#{Formatter.magenta()}[builtin]#{Formatter.reset()}"
        _ -> "[other]"
      end

    desc = skill.description || "(No description)"

    content =
      if is_selected do
        "#{theme.bold_cursor} ❯ #{scope_tag} #{Formatter.bold()}#{skill.name}#{Formatter.reset()} - #{desc}"
      else
        "   #{scope_tag} #{skill.name} - #{Formatter.dim()}#{desc}#{Formatter.reset()}"
      end

    format_box_row(content, cols, theme.border)
  end

  defp format_item_row(:diagnostics, entry, is_selected, cols, theme) do
    ts =
      if is_map(entry),
        do: Formatter.sanitize_utf8(Map.get(entry, :timestamp, "")),
        else: ""

    title =
      cond do
        is_map(entry) ->
          Formatter.sanitize_utf8(Map.get(entry, :title, ""))

        is_binary(entry) ->
          entry
          |> Formatter.sanitize_utf8()
          |> String.split("\n")
          |> List.first() || ""

        true ->
          ""
      end

    content =
      if is_selected do
        "#{theme.bold_cursor} ❯ #{Formatter.red()}●#{Formatter.reset()} #{Formatter.yellow()}[#{ts}]#{Formatter.reset()} #{theme.bold_cursor}#{title}#{Formatter.reset()}"
      else
        "   #{Formatter.red()}●#{Formatter.reset()} #{Formatter.dim()}[#{ts}]#{Formatter.reset()} #{title}"
      end

    format_box_row(content, cols, theme.border)
  end

  defp format_item_row(:analytics, %{kind: :bash_summary} = item, is_selected, cols, theme) do
    content =
      if is_selected do
        "#{theme.bold_cursor} ❯ 󱐋 Bash Analytics: #{item.total_calls} calls, #{item.ineffective_calls} ineffective (#{item.ineffective_percentage}%) [#{item.unique_commands} unique]#{Formatter.reset()}"
      else
        "   󱐋 Bash Analytics: #{item.total_calls} calls, #{item.ineffective_calls} ineffective (#{item.ineffective_percentage}%) [#{item.unique_commands} unique]"
      end

    format_box_row(content, cols, theme.border)
  end

  defp format_item_row(
         :analytics,
         %{kind: :bash_ineffective, entry: entry},
         is_selected,
         cols,
         theme
       ) do
    cmd = entry["command"] || entry[:command] || ""
    count = entry["count"] || entry[:count] || 0
    analog = entry["analog"] || entry[:analog] || ""

    content =
      if is_selected do
        "#{theme.bold_cursor} ❯ #{Formatter.yellow()}⚠ Ineffective Shell:#{Formatter.reset()} #{cmd} (#{count}x) -> #{Formatter.green()}Use #{analog}#{Formatter.reset()}"
      else
        "   #{Formatter.yellow()}⚠ Ineffective Shell:#{Formatter.reset()} #{cmd} (#{count}x) -> Use #{analog}"
      end

    format_box_row(content, cols, theme.border)
  end

  defp format_item_row(
         :analytics,
         %{kind: :bash_root, cmd: cmd, count: count, freq: freq},
         is_selected,
         cols,
         theme
       ) do
    pct = Float.round(freq * 100, 1)

    content =
      if is_selected do
        "#{theme.bold_cursor} ❯ 󰄵 Command Frequency: #{cmd} - #{count} calls (#{pct}%)#{Formatter.reset()}"
      else
        "   󰄵 Command Frequency: #{cmd} - #{count} calls (#{pct}%)"
      end

    format_box_row(content, cols, theme.border)
  end

  defp format_item_row(:analytics, %{kind: :pattern, pattern: pat}, is_selected, cols, theme) do
    seen_badge =
      if pat.seen >= 3 do
        "#{Formatter.red()}󰋗 [Tripwire: Seen #{pat.seen}x]#{Formatter.reset()}"
      else
        "#{Formatter.cyan()}󰋗 [Seen #{pat.seen}x]#{Formatter.reset()}"
      end

    content =
      if is_selected do
        "#{theme.bold_cursor} ❯ #{seen_badge} #{pat.name} (#{pat.category})#{Formatter.reset()}"
      else
        "   #{seen_badge} #{pat.name} (#{pat.category})"
      end

    format_box_row(content, cols, theme.border)
  end

  # ---------------------------------------------------------------------
  # Expandable Detail Viewport Renderer
  # ---------------------------------------------------------------------

  defp render_detail_viewport(state, cols, height, theme) do
    items = fetch_tab_items(state)

    if items == [] or state.cursor >= length(items) do
      [format_box_row("  (No item selected to inspect)", cols, theme.border)] ++
        pad_empty_rows(height - 1, cols, theme.border)
    else
      selected_item = Enum.at(items, state.cursor)
      detail_lines = format_item_detail(state.active_tab, selected_item, state)

      total_lines = length(detail_lines)
      scroll = min(state.detail_scroll, max(0, total_lines - 1))
      visible_lines = Enum.slice(detail_lines, scroll, height)

      header_banner =
        format_box_row(
          "#{theme.header_title} 🔍 Detailed Item Inspection [Scroll: #{scroll + 1}/#{total_lines}] #{Formatter.reset()}",
          cols,
          theme.border
        )

      content_rows =
        Enum.map(visible_lines, fn line ->
          format_box_row("  " <> line, cols, theme.border)
        end)

      rows = [header_banner | content_rows]
      remaining = height - length(rows)
      rows ++ pad_empty_rows(remaining, cols, theme.border)
    end
  end

  defp format_item_detail(:settings, {key, val}, state) do
    global_path = Path.expand("~/.yoke/config.json")
    local_path = Path.join(state.cwd, ".yoke/config.json")

    source =
      cond do
        File.exists?(local_path) and Map.has_key?(Config.load_config(state.cwd), key) ->
          ".yoke/config.json (Workspace Local)"

        File.exists?(global_path) ->
          "~/.yoke/config.json (Global User Default)"

        true ->
          "Yoke Kernel Default"
      end

    [
      "Setting Key:   #{Formatter.bold()}#{key}#{Formatter.reset()}",
      "Current Value: #{Formatter.cyan()}#{inspect(val, pretty: true)}#{Formatter.reset()}",
      "Value Type:    #{inspect(type_of(val))}",
      "Config Source: #{source}",
      "",
      "Actions:",
      "  - Press Space to toggle boolean values directly."
    ]
  end

  defp format_item_detail(:rules, rule, _state) do
    [
      "Rule ID:      ##{Map.get(rule, "id")}",
      "Scope:        #{Map.get(rule, "scope", "all")}",
      "Status:       #{if Map.get(rule, "enabled", true), do: "Enabled", else: "Disabled"}",
      "",
      "Rule Text:",
      "  #{Formatter.bold()}#{Map.get(rule, "text", "")}#{Formatter.reset()}",
      "",
      "Actions:",
      "  - Press Space to toggle enabled/disabled status.",
      "  - Press 'e' to edit rule text."
    ]
  end

  defp format_item_detail(:sessions, sess, _state) do
    header = [
      "Session ID:   #{sess.id}",
      "File Path:    #{sess.path}",
      "File Size:    #{sess.size} bytes",
      "Model:        #{Map.get(sess, :model, "deepseek-chat")}",
      "Total Messages: #{Map.get(sess, :msg_count, 0)}",
      "------------------------------------------------------------------"
    ]

    body =
      if File.exists?(sess.path) and String.ends_with?(sess.path, ".lmml") do
        case File.read(sess.path) do
          {:ok, content} ->
            safe_content = Formatter.sanitize_utf8(content)

            case SessionLmml.decode(safe_content) do
              {:ok, map} when is_map(map) ->
                msgs = Map.get(map, "messages") || Map.get(map, :messages) || []

                if msgs == [] do
                  safe_content
                  |> String.replace(~r/@@@[^\r\n]+[\r\n]+[\s\S]*?[\r\n]+@@@/, "")
                  |> String.trim()
                  |> Formatter.format_markdown()
                  |> String.trim_trailing()
                  |> String.split(~r/\r?\n/)
                else
                  formatted_md =
                    msgs
                    |> Enum.with_index(1)
                    |> Enum.map_join("\n\n---\n\n", fn {m, idx} ->
                      role = m["role"] || m[:role] || "unknown"
                      raw_content = m["content"] || m[:content] || ""
                      tool_calls = m["tool_calls"] || m[:tool_calls]

                      content_str = from_raw_content(raw_content)
                      role_header = role_header(role, idx)
                      tc_block = tc_block(tool_calls)

                      "#{role_header}\n\n#{content_str}#{tc_block}"
                    end)

                  formatted_md
                  |> Formatter.format_markdown()
                  |> String.trim_trailing()
                  |> String.split(~r/\r?\n/)
                end

              _ ->
                safe_content
                |> String.replace(~r/@@@[^\r\n]+[\r\n]+[\s\S]*?[\r\n]+@@@/, "")
                |> String.trim()
                |> Formatter.format_markdown()
                |> String.trim_trailing()
                |> String.split(~r/\r?\n/)
            end

          _ ->
            ["(Unreadable session log)"]
        end
      else
        ["(Compressed container or unreadable binary session log)"]
      end

    actions = [
      "",
      "Actions:",
      "  - Press 'e' to open session log in editor.",
      "  - Press 'd' to delete session file."
    ]

    header ++ body ++ actions
  end

  defp format_item_detail(:practices, prac, _state) do
    header = [
      "Practice Language: #{prac.lang}",
      "Scope:             #{prac.scope}",
      "File Path:         #{prac.path}",
      "------------------------------------------------------------------"
    ]

    body =
      if File.exists?(prac.path) do
        case File.read(prac.path) do
          {:ok, content} -> content |> Formatter.sanitize_utf8() |> String.split("\n")
          _ -> ["(File unreadable)"]
        end
      else
        ["(File not found)"]
      end

    header ++ body
  end

  defp format_item_detail(:jobs, job, _state) do
    header =
      [
        "Job ID:      #{job.id}",
        "Status:      #{inspect(Map.get(job, :status, :completed))}",
        if(job[:command], do: "Command:     #{job[:command]}", else: nil),
        "Log File:    #{job.path}",
        "Size:        #{job.size} bytes",
        "------------------------------------------------------------------"
      ]
      |> Enum.reject(&is_nil/1)

    body =
      if File.exists?(job.path) do
        case File.read(job.path) do
          {:ok, content} -> content |> Formatter.sanitize_utf8() |> String.split("\n")
          _ -> ["(Log file empty or unreadable)"]
        end
      else
        ["(Log file empty or not found)"]
      end

    actions = [
      "",
      "Actions:",
      "  - Press 'e' to open log file in editor.",
      "  - Press 'd' to delete log file."
    ]

    header ++ body ++ actions
  end

  defp format_item_detail(:skills, skill, _state) do
    header = [
      "Skill Name:   #{skill.name}",
      "Scope:        #{skill.scope}",
      "Path:         #{skill.path || "(builtin)"}",
      "Description:  #{skill.description || "none"}",
      "------------------------------------------------------------------"
    ]

    body =
      cond do
        skill.error ->
          ["Error parsing SKILL.md: #{skill.error}"]

        skill.content && skill.content != "" ->
          skill.content |> Formatter.sanitize_utf8() |> String.split("\n")

        skill.path && File.exists?(skill.path) ->
          case File.read(skill.path) do
            {:ok, content} -> content |> Formatter.sanitize_utf8() |> String.split("\n")
            _ -> ["(File unreadable)"]
          end

        true ->
          ["(No content)"]
      end

    actions =
      [
        "",
        "Actions:",
        "  - Press 'e' to edit SKILL.md in editor.",
        if(skill.scope == :project, do: "  - Press 'd' to delete project skill.", else: nil)
      ]
      |> Enum.reject(&is_nil/1)

    header ++ body ++ actions
  end

  defp format_item_detail(:diagnostics, %{raw_entry: raw}, _state) do
    safe_raw = Formatter.sanitize_utf8(raw)
    ["=== Diagnostic Report Entry ==="] ++ String.split(safe_raw, "\n")
  end

  defp format_item_detail(:diagnostics, entry, _state) when is_binary(entry) do
    safe_raw = Formatter.sanitize_utf8(entry)
    ["=== Diagnostic Report Entry ==="] ++ String.split(safe_raw, "\n")
  end

  defp format_item_detail(:analytics, %{kind: :bash_summary} = item, state) do
    path = Path.join(state.cwd, ".yoke/bash_analytics.json")

    [
      "=== Bash Invocations & Analytics Summary ===",
      "Store Path:           #{path}",
      "Total Calls:          #{item.total_calls}",
      "Unique Commands:      #{item.unique_commands}",
      "Ineffective Calls:    #{item.ineffective_calls}",
      "Ineffective Rate:     #{item.ineffective_percentage}%",
      "------------------------------------------------------------------",
      "",
      "Actions:",
      "  - Press 'e' to open .yoke/bash_analytics.json in editor.",
      "  - Press 'd' to clear bash analytics history."
    ]
  end

  defp format_item_detail(:analytics, %{kind: :bash_ineffective, entry: entry}, _state) do
    cmd = entry["command"] || entry[:command] || ""
    count = entry["count"] || entry[:count] || 0
    analog = entry["analog"] || entry[:analog] || ""
    reason = entry["reason"] || entry[:reason] || ""

    [
      "=== Ineffective Shell Pattern Details ===",
      "Shell Command:        #{cmd}",
      "Invocation Count:     #{count}",
      "Recommended Analog:   #{Formatter.green()}#{analog}#{Formatter.reset()}",
      "",
      "Rationale / Guidance:",
      "  #{reason}",
      "",
      "Tip: Calling structured Ragex MCP and dedicated Yoke tools avoids shell subshell",
      "spawning latency and returns parsed, structured output."
    ]
  end

  defp format_item_detail(
         :analytics,
         %{kind: :bash_root, cmd: cmd, count: count, freq: freq},
         _state
       ) do
    pct = Float.round(freq * 100, 1)

    [
      "=== Root Shell Command Breakdown ===",
      "Root Command:   #{cmd}",
      "Total Calls:    #{count}",
      "Frequency:      #{pct}%",
      "------------------------------------------------------------------"
    ]
  end

  defp format_item_detail(:analytics, %{kind: :pattern, pattern: pat}, state) do
    patterns_file = ReviewPatterns.patterns_path(state.cwd)

    [
      "=== Living Codebase Review Pattern ===",
      "Pattern Name:   #{pat.name}",
      "Category:       #{pat.category}",
      "Seen Count:     #{pat.seen} #{if pat.seen >= 3, do: "(Tripwire: auto-enforced)", else: ""}",
      "Store File:     #{patterns_file}",
      "------------------------------------------------------------------",
      "What it is:",
      "  #{pat.what}",
      "",
      "How to fix / avoid:",
      "  #{pat.how}",
      "",
      "Notes:",
      "  #{pat.notes}",
      "",
      "Actions:",
      "  - Press 'e' to edit review_patterns.md in editor."
    ]
  end

  defp role_header(role, idx) when is_atom(role), do: role |> Atom.to_string() |> role_header(idx)
  defp role_header("user", idx), do: "#### Turn ##{idx} — 󰍩 User"
  defp role_header("assistant", idx), do: "#### Turn ##{idx} — 󰚩 Assistant"
  defp role_header("tool", idx), do: "#### Turn ##{idx} — 🛠 Tool Result"
  defp role_header("system", idx), do: "#### Turn ##{idx} — ⚙ System"
  defp role_header(other, idx), do: "#### Turn ##{idx} — #{String.capitalize(other)}"

  defp tc_block([_ | _] = tool_calls) do
    tc_items =
      Enum.map_join(tool_calls, "\n", fn tc ->
        fn_map = Map.get(tc, "function", tc) || tc
        name = Map.get(fn_map, "name") || Map.get(fn_map, :name) || "tool"
        args = Map.get(fn_map, "arguments") || Map.get(fn_map, :arguments) || "{}"

        "- `#{name}(#{args})`"
      end)

    "\n\n**Tool Calls Executed:**\n" <> tc_items
  end

  defp tc_block(_), do: ""

  defp from_raw_content(raw_content) when is_binary(raw_content), do: raw_content
  defp from_raw_content(raw_content) when is_atom(raw_content), do: Atom.to_string(raw_content)

  defp from_raw_content(raw_content) when is_list(raw_content) do
    Enum.map_join(raw_content, "\n", fn
      %{"text" => t} -> t
      %{text: t} -> t
      other -> inspect(other)
    end)
  end

  defp from_raw_content(raw_content), do: inspect(raw_content)

  defp type_of(v) when is_boolean(v), do: :boolean
  defp type_of(v) when is_integer(v), do: :integer
  defp type_of(v) when is_float(v), do: :float
  defp type_of(v) when is_binary(v), do: :string
  defp type_of(v) when is_map(v), do: :map
  defp type_of(v) when is_list(v), do: :list
  defp type_of(_), do: :other

  # ---------------------------------------------------------------------
  # Tab Themes & Color Palette
  # ---------------------------------------------------------------------

  def tab_theme(:settings) do
    %{
      border: "\e[38;5;39m",
      header_title: "\e[1;38;5;39m",
      pill_bg: "\e[48;5;39;30m",
      bold_cursor: "\e[1;38;5;39m"
    }
  end

  def tab_theme(:rules) do
    %{
      border: "\e[38;5;220m",
      header_title: "\e[1;38;5;220m",
      pill_bg: "\e[48;5;220;30m",
      bold_cursor: "\e[1;38;5;220m"
    }
  end

  def tab_theme(:sessions) do
    %{
      border: "\e[38;5;177m",
      header_title: "\e[1;38;5;177m",
      pill_bg: "\e[48;5;177;30m",
      bold_cursor: "\e[1;38;5;177m"
    }
  end

  def tab_theme(:practices) do
    %{
      border: "\e[38;5;42m",
      header_title: "\e[1;38;5;42m",
      pill_bg: "\e[48;5;42;30m",
      bold_cursor: "\e[1;38;5;42m"
    }
  end

  def tab_theme(:jobs) do
    %{
      border: "\e[38;5;214m",
      header_title: "\e[1;38;5;214m",
      pill_bg: "\e[48;5;214;30m",
      bold_cursor: "\e[1;38;5;214m"
    }
  end

  def tab_theme(:skills) do
    %{
      border: "\e[38;5;51m",
      header_title: "\e[1;38;5;51m",
      pill_bg: "\e[48;5;51;30m",
      bold_cursor: "\e[1;38;5;51m"
    }
  end

  def tab_theme(:diagnostics) do
    %{
      border: "\e[38;5;196m",
      header_title: "\e[1;38;5;196m",
      pill_bg: "\e[48;5;196;30m",
      bold_cursor: "\e[1;38;5;196m"
    }
  end

  def tab_theme(:analytics) do
    %{
      border: "\e[38;5;141m",
      header_title: "\e[1;38;5;141m",
      pill_bg: "\e[48;5;141;30m",
      bold_cursor: "\e[1;38;5;141m"
    }
  end

  def tab_theme(_) do
    tab_theme(:settings)
  end

  # ---------------------------------------------------------------------
  # TUI Main Loop & Raw Mode Terminal Controls
  # ---------------------------------------------------------------------

  def run_tty(cwd, _opts) do
    enter_alternate_screen()
    set_raw_mode()
    state = new_state(cwd)

    try do
      tui_loop(state)
    after
      TerminalOwner.clear()
      restore_tty_mode()
      exit_alternate_screen()
    end
  end

  defp tui_loop(state) do
    render_full_screen(state)
    TerminalOwner.set(&erase_for_log/1, &redraw_for_log/1, state)

    case read_key() do
      :tab ->
        tui_loop(switch_tab(state, 1))

      :shift_tab ->
        tui_loop(switch_tab(state, -1))

      :right ->
        tui_loop(switch_tab(state, 1))

      :left ->
        tui_loop(switch_tab(state, -1))

      :up ->
        tui_loop(move_cursor(state, -1))

      :down ->
        tui_loop(move_cursor(state, 1))

      :page_up ->
        tui_loop(move_cursor(state, -10))

      :page_down ->
        tui_loop(move_cursor(state, 10))

      :home ->
        tui_loop(%{state | cursor: 0, detail_scroll: 0})

      :enter ->
        tui_loop(handle_select(state))

      :space ->
        tui_loop(handle_toggle(state))

      {:char, ?e} ->
        tui_loop(handle_edit(state))

      {:char, ?a} ->
        tui_loop(handle_add_rule(state))

      {:char, ?d} ->
        tui_loop(handle_delete(state))

      {:char, ?r} ->
        tui_loop(refresh_state(state, "Refreshed configuration tree."))

      {:char, ?q} ->
        if state.view_mode == :detail do
          tui_loop(%{state | view_mode: :list, detail_scroll: 0})
        else
          :ok
        end

      :escape ->
        if state.view_mode == :detail do
          tui_loop(%{state | view_mode: :list, detail_scroll: 0})
        else
          :ok
        end

      :ctrl_c ->
        :ok

      {:char, c} when c >= ?1 and c <= ?8 ->
        idx = c - ?1
        tab = Enum.at(@tabs, idx)
        tui_loop(%{state | tab_index: idx, active_tab: tab, cursor: 0, view_mode: :list})

      _ ->
        tui_loop(state)
    end
  end

  defp erase_for_log(_state), do: :ok
  defp redraw_for_log(state), do: render_full_screen(state)

  def run_non_tty(cwd, _opts) do
    tree = scan_directory_tree(cwd)
    output = format_non_tty_summary(tree)
    IO.puts(output)
    {:ok, output}
  end

  def format_non_tty_summary(tree) do
    skills_count = if is_list(tree[:skills]), do: length(tree.skills), else: 0
    patterns_count = if is_list(tree[:patterns]), do: length(tree.patterns), else: 0
    bash_calls = get_in(tree, [:analytics, :total_calls]) || 0
    bash_ineffective = get_in(tree, [:analytics, :ineffective_calls]) || 0

    """
    === Yoke Config Directory Explorer Summary ===
    Local path: #{tree.local_dir}
    Global path: #{tree.global_dir}

    ● Config keys (#{map_size(tree.config)}):
      Model: #{tree.config["model"]}
      Permission mode: #{tree.config["permission_mode"]}
      Plan gate: #{tree.config["plan_gate_enabled"]} (threshold: #{tree.config["plan_gate_threshold"]})
      God mode: #{tree.config["god_mode"]}

    ● Prompt Rules (#{length(tree.rules)} active)
    ● Saved Sessions/Conversations (#{length(tree.sessions)} files)
    ● Practice Manifests (#{length(tree.practices)} loaded)
    ● Job Logs (#{length(tree.jobs)} files in .yoke/jobs/)
    ● Custom & Discovered Skills (#{skills_count} loaded)
    ● Living Review Patterns (#{patterns_count} registered)
    ● Bash Command Analytics (#{bash_calls} calls, #{bash_ineffective} ineffective)
    ● Logged Diagnostic Errors (#{tree.errors.count} entries in ERRORS_TO_FIX.lmml)
    =============================================
    """
  end

  # Terminal alternate buffer helpers
  defp enter_alternate_screen do
    IO.write(:user, "\e[?1049h\e[H\e[2J")
  end

  defp exit_alternate_screen do
    IO.write(:user, "\e[?1049l")
  end

  defp terminal_dimensions do
    cols =
      case :io.columns(:user) do
        {:ok, c} when is_integer(c) and c > 20 ->
          c

        _ ->
          case :io.columns() do
            {:ok, c} when is_integer(c) and c > 20 -> c
            _ -> 120
          end
      end

    rows =
      case :io.rows(:user) do
        {:ok, r} when is_integer(r) and r > 5 ->
          r

        _ ->
          case :io.rows() do
            {:ok, r} when is_integer(r) and r > 5 -> r
            _ -> 35
          end
      end

    {cols, rows}
  end

  defp tty? do
    if (function_exported?(Mix, :env, 0) and Mix.env() == :test) or
         System.get_env("CI") != nil or
         Application.get_env(:yoke, :non_interactive, false) do
      false
    else
      case :io.columns(:user) do
        {:ok, _} ->
          true

        _ ->
          case :io.columns() do
            {:ok, _} -> true
            _ -> false
          end
      end
    end
  end

  defp set_raw_mode do
    case :shell.start_interactive({:noshell, :raw}) do
      :ok -> :ok
      {:error, :already_started} -> :ok
    end
  rescue
    _ -> :error
  end

  defp restore_tty_mode do
    case :shell.start_interactive({:noshell, :cooked}) do
      :ok -> :ok
      {:error, :already_started} -> :ok
    end
  rescue
    _ -> :ok
  end

  defp read_key do
    case get_raw_input_chunk() do
      :eof -> :eof
      other -> match_key(other)
    end
  end

  defp match_key("\e[A"), do: :up
  defp match_key("\e[B"), do: :down
  defp match_key("\e[C"), do: :right
  defp match_key("\e[D"), do: :left
  defp match_key("\eOA"), do: :up
  defp match_key("\eOB"), do: :down
  defp match_key("\eOC"), do: :right
  defp match_key("\eOD"), do: :left
  defp match_key("\e[Z"), do: :shift_tab
  defp match_key("\e[5~"), do: :page_up
  defp match_key("\e[6~"), do: :page_down
  defp match_key("\e[H"), do: :home
  defp match_key("\e[F"), do: :end
  defp match_key("\r"), do: :enter
  defp match_key("\n"), do: :enter
  defp match_key("\t"), do: :tab
  defp match_key(" "), do: :space
  defp match_key("\e"), do: :escape
  defp match_key("\x03"), do: :ctrl_c

  defp match_key(other) when is_binary(other) do
    cond do
      String.contains?(other, "[A") or String.contains?(other, "OA") ->
        :up

      String.contains?(other, "[B") or String.contains?(other, "OB") ->
        :down

      String.contains?(other, "[C") or String.contains?(other, "OC") ->
        :right

      String.contains?(other, "[D") or String.contains?(other, "OD") ->
        :left

      true ->
        case other do
          <<c::utf8, _rest::binary>> -> {:char, c}
          _ -> :other
        end
    end
  end

  defp get_raw_input_chunk do
    case read_char() do
      "\e" ->
        seq = read_available_escape_bytes("", 6)
        "\e" <> seq

      :eof ->
        :eof

      char when is_binary(char) ->
        char
    end
  end

  defp read_char_with_timeout(timeout_ms) do
    task = Task.async(fn -> read_char() end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      _ -> nil
    end
  end

  defp read_available_escape_bytes(acc, count) when count > 0 do
    case read_char_with_timeout(25) do
      char when is_binary(char) and char != "" ->
        new_acc = acc <> char

        if char in ["A", "B", "C", "D", "H", "F", "~"] do
          new_acc
        else
          read_available_escape_bytes(new_acc, count - 1)
        end

      _ ->
        acc
    end
  end

  defp read_available_escape_bytes(acc, _count), do: acc

  defp read_char do
    case IO.getn(:user, "", 1) do
      :eof -> :eof
      {:error, _reason} -> :eof
      char when is_binary(char) -> char
      char when is_list(char) -> IO.iodata_to_binary(char)
    end
  end
end
