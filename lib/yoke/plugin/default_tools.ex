defmodule Yoke.Plugin.DefaultTools do
  @moduledoc false
  @behaviour Yoke.Plugin.Behaviour

  @impl true
  def name, do: "DefaultTools"

  @impl true
  def description,
    do:
      "Provides default workspace tools: read_file, read_files, write_file, replace_file, list_dir, bash, elixir_eval, ask_question, and import_session."

  @impl true
  def tools do
    [
      %{
        name: "read_file",
        description:
          "Read text content of a SINGLE file given its path. Optionally pass `start_line` and `end_line` (1-indexed integers) to read a specific line range, avoiding raw shell commands like head, tail, or sed.",
        parameters: %{
          type: "object",
          properties: %{
            path: %{type: "string", description: "Relative or absolute path to the file."},
            start_line: %{
              type: "integer",
              description: "Optional 1-indexed starting line number."
            },
            end_line: %{
              type: "integer",
              description: "Optional 1-indexed ending line number."
            }
          },
          required: ["path"]
        },
        execute: &read_file/1
      },
      %{
        name: "read_files",
        description:
          "Read several files in parallel in a single tool call. Prefer this over issuing multiple read_file calls when you need to inspect several files at once (e.g. a module and its tests, or a set of related source files). Returns each file's contents delimited by a clear header, so you can see exactly which content belongs to which path. If any file cannot be read, its error is reported inline without failing the others.",
        parameters: %{
          type: "object",
          properties: %{
            paths: %{
              type: "array",
              description: "List of relative or absolute file paths to read.",
              items: %{type: "string"}
            }
          },
          required: ["paths"]
        },
        execute: &read_files/1
      },
      %{
        name: "write_file",
        description: "Write or create a file with specified text content.",
        parameters: %{
          type: "object",
          properties: %{
            path: %{type: "string", description: "Target file path."},
            content: %{type: "string", description: "Content to write into the file."}
          },
          required: ["path", "content"]
        },
        execute: &write_file/1
      },
      %{
        name: "replace_file",
        description: "Replace exact target string with replacement string in a file.",
        parameters: %{
          type: "object",
          properties: %{
            path: %{type: "string", description: "File path."},
            target: %{type: "string", description: "Exact target substring to find and replace."},
            replacement: %{type: "string", description: "Replacement text."}
          },
          required: ["path", "target", "replacement"]
        },
        execute: &replace_file/1
      },
      %{
        name: "list_dir",
        description: "List directory contents (files and subdirectories).",
        parameters: %{
          type: "object",
          properties: %{
            path: %{
              type: "string",
              description: "Directory path (defaults to current directory '.')."
            }
          },
          required: []
        },
        execute: &list_dir/1
      },
      %{
        name: "bash",
        description:
          "Execute a shell bash command and return standard output / error. User toolchain paths (~/.asdf/shims, ~/.cargo/bin, ERL_HOME) are automatically loaded. Pass `async: true` for long-running build/test tasks (`mix compile`, `mix test`, `cargo build`) to run them in the background without blocking. Returns a job ID immediately when `async: true` and automatically sends a completion message to the session when finished. Do NOT poll `job_status` or run polling bash loops (`pgrep`, `sleep`). STRICT RESTRICTION: Do NOT use bash with grep, sed, find, cat, head, tail, or xargs for code searching, symbol finding, or reading file content -- use read_file (with start_line/end_line), read_files, or grep_search instead.",
        parameters: %{
          type: "object",
          properties: %{
            command: %{type: "string", description: "The bash command string to execute."},
            async: %{
              type: "boolean",
              description:
                "Set to true to run command asynchronously in the background (default: false)."
            }
          },
          required: ["command"]
        },
        execute: &execute_bash/1
      },
      %{
        name: "job_status",
        description:
          "Inspect recent log output and status of a running or finished background job. Background jobs notify the session automatically upon completion; use job_status only if you specifically need to inspect intermediate logs of an active job while performing other work.",
        parameters: %{
          type: "object",
          properties: %{
            job_id: %{type: "string", description: "The background job ID (e.g. 'job_1')."},
            tail: %{
              type: "integer",
              description: "Number of recent log lines to return (default: 30)."
            }
          },
          required: ["job_id"]
        },
        execute: &job_status_tool/1
      },
      %{
        name: "job_kill",
        description: "Terminates a running background job started via bash(async: true).",
        parameters: %{
          type: "object",
          properties: %{
            job_id: %{type: "string", description: "The background job ID to terminate."}
          },
          required: ["job_id"]
        },
        execute: &job_kill_tool/1
      },
      %{
        name: "grep_search",
        description:
          "Search for a pattern or substring across files in the workspace. Use this instead of running raw shell grep commands in bash.",
        parameters: %{
          type: "object",
          properties: %{
            path: %{
              type: "string",
              description: "Target directory or file path to search (default: '.')."
            },
            query: %{type: "string", description: "String or regex pattern to search for."},
            path_pattern: %{
              type: "string",
              description: "Optional file glob pattern to filter search (e.g. '*.ex')."
            }
          },
          required: ["query"]
        },
        execute: &grep_search_tool/1
      },
      %{
        name: "elixir_eval",
        description:
          "Evaluates Elixir code string directly in the runtime and returns the result.",
        parameters: %{
          type: "object",
          properties: %{
            code: %{type: "string", description: "Elixir code snippet to evaluate."}
          },
          required: ["code"]
        },
        execute: &evaluate_elixir/1
      },
      %{
        name: "ask_question",
        description:
          "Ask the user one or more multiple-choice questions or request user feedback/clarification via interactive CLI UI modal.",
        parameters: %{
          type: "object",
          properties: %{
            questions: %{
              type: "array",
              description: "The list of questions to ask the user.",
              items: %{
                type: "object",
                properties: %{
                  question: %{
                    type: "string",
                    description: "The question prompt to ask the user."
                  },
                  options: %{
                    type: "array",
                    items: %{type: "string"},
                    description: "List of selectable options for the user."
                  },
                  is_multi_select: %{
                    type: "boolean",
                    description: "Whether the user can select multiple options (default: false)."
                  }
                },
                required: ["question", "options"]
              }
            }
          },
          required: ["questions"]
        },
        execute: &ask_question/1
      },
      %{
        name: "import_session",
        description:
          "Imports an externally-produced session file into Yoke's own on-disk session store (.yoke/sessions/<id>.lmml), so it can be resumed via /resume or /session switch. Accepts an .lmml conversation narrative, a top-level {\"messages\": [...]} JSON object, a bare JSON array of messages, or the native session/export schema. Replaces converting/importing sessions via an external script.",
        parameters: %{
          type: "object",
          properties: %{
            path: %{
              type: "string",
              description: "Path to the source session file (.lmml or JSON) to import."
            },
            session_id: %{
              type: "string",
              description:
                "Target session ID to import as (defaults to the source file's own 'session_id', or a freshly generated ID)."
            },
            overwrite: %{
              type: "boolean",
              description:
                "Whether to overwrite an existing session with the same ID (default: false)."
            }
          },
          required: ["path"]
        },
        execute: &import_session/1
      },
      %{
        name: "spawn_subagent",
        description:
          "Spawns an independent background subagent worker session to execute a sub-task concurrently, in parallel with your own continued work in this turn. Use `async: true` (the default) for fire-and-forget parallel work -- this returns immediately, and the subagent's final response is appended to this conversation as a new message once it completes. Use `async: false` to block and receive the subagent's final response directly as this tool call's result. Prefer this whenever breaking down complex or multi-step work into independent, parallelizable sub-tasks instead of doing them one after another yourself.",
        parameters: %{
          type: "object",
          properties: %{
            prompt: %{
              type: "string",
              description: "The task/instructions to hand off to the subagent, in full detail."
            },
            async: %{
              type: "boolean",
              description: "Whether to run the subagent asynchronously (default: true)."
            }
          },
          required: ["prompt"]
        },
        execute: &spawn_subagent/1
      },
      %{
        name: "run_workflow",
        description:
          "Runs a customizable, multi-step Yoke workflow end-to-end (e.g. 'elixir': create a branch, summarize the task, propose a non-clashing parallel split, require tests + docs, lint, and commit). Use this ONLY when the user explicitly asks to run/kick off/start a named workflow for a task -- it can take a long time and may pause for interactive user confirmation (branch warnings, split-plan approval).",
        parameters: %{
          type: "object",
          properties: %{
            workflow: %{
              type: "string",
              description:
                "Name of the workflow to run (e.g. 'elixir'). See /workflow list for available names."
            },
            task_description: %{
              type: "string",
              description: "The task to accomplish, in the user's own words."
            }
          },
          required: ["workflow", "task_description"]
        },
        execute: &run_workflow/1
      },
      %{
        name: "glob_search",
        description: "Find files in the workspace matching a glob pattern (e.g. 'lib/**/*.ex').",
        parameters: %{
          type: "object",
          properties: %{
            pattern: %{type: "string", description: "Glob pattern to match files."}
          },
          required: ["pattern"]
        },
        execute: &glob_search/1
      },
      %{
        name: "run_linter",
        description:
          "Run native Elixir linters and tools (oeditus_credo, propwise, credo, dialyzer) against whole project, diff, or CR targets.",
        parameters: %{
          type: "object",
          properties: %{
            args: %{
              type: "string",
              description:
                "Linter command arguments (e.g. 'propwise cr main', 'oeditus_credo diff', 'propwise', 'all cr main')."
            }
          },
          required: ["args"]
        },
        execute: &linter_tool/1
      },
      %{
        name: "yaml_format",
        description: "Formats JSON or YAML text with pretty indentation.",
        parameters: %{
          type: "object",
          properties: %{
            text: %{type: "string", description: "JSON or YAML formatted text."}
          },
          required: ["text"]
        },
        execute: &yaml_format/1
      },
      %{
        name: "git_status",
        description: "Returns active repository git status (short format).",
        parameters: %{type: "object", properties: %{}},
        execute: &git_status_tool/1
      },
      %{
        name: "git_diff",
        description: "Returns workspace git diff.",
        parameters: %{type: "object", properties: %{}},
        execute: &git_diff_tool/1
      },
      %{
        name: "git_commit",
        description:
          "Stages workspace changes and creates a git commit with the specified message.",
        parameters: %{
          type: "object",
          properties: %{
            message: %{type: "string", description: "Commit message."}
          },
          required: ["message"]
        },
        execute: &git_commit_tool/1
      },
      %{
        name: "git_root",
        description:
          "Returns the absolute top-level root directory path of the active git repository (git rev-parse --show-toplevel). Use this instead of running raw bash shell commands like 'git rev-parse --show-toplevel'.",
        parameters: %{type: "object", properties: %{}},
        execute: &git_root_tool/1
      }
    ]
  end

  def read_file(%{"path" => path} = args) do
    case File.read(path) do
      {:ok, content} ->
        start_line = Map.get(args, "start_line")
        end_line = Map.get(args, "end_line")

        if start_line || end_line do
          lines = String.split(content, ~r/\r?\n/)
          total = length(lines)
          s = (start_line || 1) |> max(1)
          e = (end_line || total) |> min(total)

          sliced =
            lines
            |> Enum.slice((s - 1)..(e - 1))
            |> Enum.with_index(s)
            |> Enum.map_join("\n", fn {line, num} -> "#{num}: #{line}" end)

          {:ok, "=== Lines #{s}-#{e} of #{path} (total #{total} lines) ===\n" <> sliced}
        else
          {:ok, content}
        end

      {:error, reason} ->
        {:error, "Failed to read file '#{path}': #{inspect(reason)}"}
    end
  end

  @doc """
  Reads several files concurrently in a single tool call.
  """
  def read_files(%{"paths" => paths}) when is_list(paths) do
    paths
    |> Enum.with_index()
    |> Task.async_stream(
      fn {path, _idx} ->
        case File.read(path) do
          {:ok, content} -> {:ok, path, content}
          {:error, reason} -> {:error, path, reason}
        end
      end,
      max_concurrency: System.schedulers_online(),
      ordered: true,
      timeout: 30_000
    )
    |> Enum.map_join("\n", fn
      {:ok, {:ok, path, content}} ->
        "=== File: #{path} ===\n#{content}\n"

      {:ok, {:error, path, reason}} ->
        "=== File: #{path} ===\n[ERROR] Failed to read file: #{inspect(reason)}\n"

      {:exit, reason} ->
        "[ERROR] A file read crashed: #{inspect(reason)}\n"
    end)
    |> then(&{:ok, &1})
  end

  def read_files(%{"paths" => paths}) do
    {:error,
     "Invalid 'paths' argument for read_files. Expected a list of file paths, got: #{inspect(paths)}"}
  end

  def read_files(_args) do
    {:error,
     "Invalid arguments for read_files. Expected a 'paths' list of file paths to read, e.g. %{\"paths\" => [\"a.ex\", \"b.ex\"]}"}
  end

  def write_file(%{"path" => path, "content" => content}) do
    with :ok <- path |> Path.dirname() |> File.mkdir_p(),
         :ok <- File.write(path, content) do
      {:ok, "Successfully wrote #{byte_size(content)} bytes to #{path}"}
    else
      {:error, reason} -> {:error, "Failed to write file '#{path}': #{inspect(reason)}"}
    end
  end

  def replace_file(%{"path" => path, "target" => target, "replacement" => replacement}) do
    case File.read(path) do
      {:ok, content} ->
        if String.contains?(content, target) do
          updated = String.replace(content, target, replacement)

          case File.write(path, updated) do
            :ok -> {:ok, "Successfully replaced target text in #{path}"}
            {:error, reason} -> {:error, "Failed to write to file '#{path}': #{inspect(reason)}"}
          end
        else
          {:error, "Target text not found in #{path}"}
        end

      {:error, reason} ->
        {:error, "Failed to read file '#{path}': #{inspect(reason)}"}
    end
  end

  def list_dir(args) do
    dir = Map.get(args, "path", ".")

    case File.ls(dir) do
      {:ok, files} ->
        detailed = Enum.map_join(files, "\n", &format_file_entry(dir, &1))
        {:ok, "Contents of #{dir}:\n" <> detailed}

      {:error, reason} ->
        {:error, "Failed to list directory '#{dir}': #{inspect(reason)}"}
    end
  end

  defp format_file_entry(dir, f) do
    type = if File.dir?(Path.join(dir, f)), do: "[DIR]", else: "[FILE]"
    "#{type} #{f}"
  end

  def execute_bash(%{"command" => cmd} = args) do
    if Map.get(args, "async", false) do
      cwd = Map.get(args, "_session_cwd", File.cwd!())
      session_id = Map.get(args, "_session_id")

      # `start_job/2` either returns `{:ok, job_id, log_file}` or raises; any
      # failure to spawn the job is turned into an error tuple by the
      # function-level `rescue` below.
      {:ok, job_id, log_file} =
        Yoke.TaskEngine.JobManager.start_job(cmd, cwd: cwd, session_id: session_id)

      {:ok,
       "Started background job '#{job_id}' (log: #{log_file}) as an asynchronous OTP process. The job will notify this session automatically upon completion. Continue with other work or complete your turn without polling."}
    else
      {env, exec_cmd} = Yoke.TaskEngine.JobManager.prepare_environment(cmd)

      case System.cmd("sh", ["-c", exec_cmd], env: env, stderr_to_stdout: true) do
        {output, 0} -> {:ok, output}
        {output, code} -> {:ok, "Command exited with status #{code}:\n#{output}"}
      end
    end
  rescue
    e -> {:error, "Execution exception: #{inspect(e)}"}
  end

  def job_status_tool(%{"job_id" => job_id} = args) do
    tail = Map.get(args, "tail", 30)

    case Yoke.TaskEngine.JobManager.get_job_status(job_id, tail: tail) do
      {:ok, out} -> {:ok, out}
      {:error, err} -> {:error, err}
    end
  end

  def job_status_tool(_args) do
    {:error, "Invalid arguments for job_status. Expected 'job_id' string."}
  end

  def job_kill_tool(%{"job_id" => job_id}) do
    case Yoke.TaskEngine.JobManager.kill_job(job_id) do
      {:ok, out} -> {:ok, out}
      {:error, err} -> {:error, err}
    end
  end

  def job_kill_tool(_args) do
    {:error, "Invalid arguments for job_kill. Expected 'job_id' string."}
  end

  def grep_search_tool(%{"query" => query} = args) when is_binary(query) do
    dir = Map.get(args, "path", ".")
    path_pattern = Map.get(args, "path_pattern", "**/*")

    target_pattern =
      if File.dir?(dir) do
        Path.join(dir, path_pattern)
      else
        dir
      end

    files =
      if File.regular?(dir) do
        [dir]
      else
        Path.wildcard(target_pattern)
        |> Enum.filter(&File.regular?/1)
      end

    case Regex.compile(query, [:caseless]) do
      {:ok, regex} ->
        matches =
          files
          |> Enum.take(200)
          |> Enum.flat_map(fn file ->
            case File.read(file) do
              {:ok, content} ->
                content
                |> String.split(~r/\r?\n/)
                |> Enum.with_index(1)
                |> Enum.filter(fn {line, _num} -> Regex.match?(regex, line) end)
                |> Enum.map(fn {line, num} -> "#{file}:#{num}: #{String.trim(line)}" end)

              _ ->
                []
            end
          end)
          |> Enum.take(100)

        if matches == [] do
          {:ok, "No matches found for '#{query}'."}
        else
          {:ok, "Found #{length(matches)} matches:\n" <> Enum.join(matches, "\n")}
        end

      {:error, reason} ->
        {:error, "Invalid regex pattern '#{query}': #{inspect(reason)}"}
    end
  end

  def grep_search_tool(_args) do
    {:error, "Invalid arguments for grep_search. Expected 'query' string."}
  end

  def evaluate_elixir(%{"code" => code}) do
    {result, _bindings} = Code.eval_string(code)
    {:ok, inspect(result, pretty: true)}
  rescue
    e -> {:error, "Evaluation exception: #{Exception.format(:error, e, __STACKTRACE__)}"}
  end

  def ask_question(args) do
    questions =
      cond do
        is_list(args["questions"]) -> args["questions"]
        is_binary(args["question"]) and is_list(args["options"]) -> [args]
        true -> []
      end

    if questions == [] do
      {:error,
       "Invalid arguments for ask_question. Expected 'questions' list containing 'question' and 'options'."}
    else
      # Pause the spinner while the question modal is displayed so its
      # periodic terminal redraws don't interleave with the modal's output.
      result =
        Yoke.CLI.Spinner.with_paused(fn ->
          Yoke.CLI.QuestionPrompt.ask(questions)
        end)

      {:ok, result}
    end
  end

  def import_session(%{"path" => path} = args) do
    opts = [
      session_id: Map.get(args, "session_id"),
      overwrite: Map.get(args, "overwrite", false)
    ]

    case Yoke.Brain.SessionStore.import_session(path, opts) do
      {:ok, session_id, file_path} ->
        {:ok, "Imported session '#{session_id}' -> #{file_path}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def import_session(_args) do
    {:error,
     "Invalid arguments for import_session. Expected 'path' to a session .lmml or JSON file."}
  end

  @doc """
  Spawns an independent subagent worker session to run `args["prompt"]` as
  its own agentic turn.

  `_session_id`/`_session_model`/`_session_cwd` are injected server-side by
  `Yoke.TaskEngine.Orchestrator` (never declared to or supplied
  by the model -- see `tools/0`'s `spawn_subagent` parameter schema, which
  only exposes `prompt`/`async`) so this can identify and report back to
  the calling session without needing a live PID passed through the tool
  call arguments.

  Deliberately does NOT route through `Yoke.Brain.Session.spawn_subagent/3`
  (a `GenServer.call` back into the very session invoking this tool): this
  code runs from inside that same session's own in-flight turn (see
  `Orchestrator.execute_batch/3`), which is synchronously blocked awaiting
  this and any sibling tool calls to finish. Calling back into it here
  would deadlock until the batch's own execution timeout expired. Spawning
  the child session directly, and delivering the async result via a plain
  (non-blocking) `send/2` instead of a `GenServer.call`, sidesteps that
  reentrancy hazard entirely.
  """
  def spawn_subagent(%{"prompt" => prompt} = args) when is_binary(prompt) do
    if String.trim(prompt) == "" do
      {:error, "spawn_subagent requires a non-empty 'prompt' argument."}
    else
      if Map.get(args, "async", true) do
        spawn_subagent_async(args, prompt)
      else
        spawn_subagent_sync(args, prompt)
      end
    end
  end

  def spawn_subagent(_args) do
    {:error, "Invalid arguments for spawn_subagent. Expected a non-empty 'prompt' string."}
  end

  defp spawn_subagent_async(args, prompt) do
    sub_id = "sub_#{System.unique_integer([:positive])}"
    parent_session_id = Map.get(args, "_session_id")
    model = Map.get(args, "_session_model")
    cwd = Map.get(args, "_session_cwd", ".")

    Task.start(fn ->
      result = run_subagent_turn(sub_id, model, cwd, prompt)
      notify_parent_session(parent_session_id, sub_id, result)
    end)

    {:ok,
     "Subagent '#{sub_id}' spawned asynchronously; its result will be appended to this conversation once it completes."}
  end

  defp spawn_subagent_sync(args, prompt) do
    sub_id = "sub_#{System.unique_integer([:positive])}"
    model = Map.get(args, "_session_model")
    cwd = Map.get(args, "_session_cwd", ".")

    case run_subagent_turn(sub_id, model, cwd, prompt) do
      {:ok, %{content: content}} -> {:ok, content}
      {:ok, text} when is_binary(text) -> {:ok, text}
      {:error, err} -> {:error, err}
    end
  end

  defp run_subagent_turn(sub_id, model, cwd, prompt) do
    # Register this subagent as a running "package" so the status bar & spinner
    # surface it while it works; registration is process-linked to this Task, so
    # it auto-unregisters when the turn finishes (or crashes).
    Yoke.TaskEngine.PackageTracker.register(
      "sub: " <> Yoke.TaskEngine.PackageTracker.derive_label(prompt),
      :subagent,
      id: sub_id
    )

    try do
      case Yoke.Brain.SessionSupervisor.start_session(
             session_id: sub_id,
             model: model,
             cwd: cwd
           ) do
        {:ok, sub_pid} ->
          result = Yoke.Brain.Session.send_user_message(sub_pid, prompt)
          Yoke.Brain.SessionSupervisor.stop_session(sub_pid)
          result

        {:error, err} ->
          {:error, "Failed to spawn subagent: #{inspect(err)}"}
      end
    after
      Yoke.TaskEngine.PackageTracker.unregister()
    end
  end

  defp notify_parent_session(parent_session_id, sub_id, result)
       when is_binary(parent_session_id) do
    case Registry.lookup(Yoke.Registry, "session_" <> parent_session_id) do
      [{parent_pid, _}] -> send(parent_pid, {:subagent_completed, sub_id, result})
      [] -> :ok
    end
  end

  defp notify_parent_session(_parent_session_id, _sub_id, _result), do: :ok

  def run_workflow(%{"workflow" => name, "task_description" => description})
      when is_binary(name) and is_binary(description) do
    case Yoke.Workflow.Engine.run(name, seed_prompt: description) do
      {:ok, context} ->
        {:ok, "Workflow '#{name}' completed successfully (run '#{context.run_id}')."}

      {:halt, reason} ->
        {:ok, "Workflow '#{name}' halted before completion: #{reason}"}

      {:error, reason} ->
        {:error, "Workflow '#{name}' failed: #{inspect(reason)}"}
    end
  end

  def run_workflow(_args) do
    {:error,
     "Invalid arguments for run_workflow. Expected 'workflow' (name) and 'task_description' strings."}
  end

  def glob_search(%{"pattern" => pattern}) do
    matches = Path.wildcard(pattern)

    if Enum.empty?(matches) do
      {:ok, "No files matched pattern: '#{pattern}'"}
    else
      {:ok, "Matched #{length(matches)} files:\n" <> Enum.join(matches, "\n")}
    end
  end

  def yaml_format(%{"text" => text}) do
    case Yoke.Json.decode(text) do
      {:ok, data} -> {:ok, Yoke.Json.encode!(data, pretty: true)}
      {:error, _} -> {:ok, String.trim(text)}
    end
  end

  def git_status_tool(_args) do
    case Yoke.Git.status() do
      {:ok, out} -> {:ok, out}
      {:error, err} -> {:error, err}
    end
  end

  def git_diff_tool(_args) do
    case Yoke.Git.diff() do
      {:ok, out} -> {:ok, out}
      {:error, err} -> {:error, err}
    end
  end

  def git_commit_tool(%{"message" => message}) do
    case Yoke.Git.commit(message) do
      {:ok, out} -> {:ok, out}
      {:error, err} -> {:error, err}
    end
  end

  def git_root_tool(_args) do
    case Yoke.Git.root_dir() do
      {:ok, out} -> {:ok, out}
      {:error, err} -> {:error, err}
    end
  end

  def linter_tool(%{"args" => args}) do
    case Yoke.Linter.run(args) do
      {:ok, out} -> {:ok, out}
      {:error, err} -> {:error, err}
    end
  end
end
