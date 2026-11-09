defmodule Yoke.CLI.Help do
  @moduledoc """
  Contextual slash-command documentation without executing the documented command.
  """

  alias Yoke.CLI.Formatter

  @aliases %{
    "aliases" => "alias",
    "cb" => "clipboard",
    "conversation" => "review_conversation",
    "cr" => "review",
    "cpr" => "commit-structured",
    "docs" => "guide",
    "getting-started" => "guide",
    "lint" => "linter",
    "models" => "model",
    "pr" => "finish",
    "prboard" => "review",
    "quit" => "exit",
    "review-conversation" => "review_conversation",
    "skill" => "skills",
    "status" => "session"
  }

  @commands %{
    "!" => """
    !<command>
    Execute a shell command directly, outside the model/tool loop.
    Example: !git status
    """,
    "!!" => """
    !!
    Toggle pure console mode: plain shell passthrough without model or slash-command dispatch.
    Type !! again to return to Yoke.
    """,
    "alias" => """
    /alias [list]
    /alias show <name>
    /alias add <name> <command>
    /alias rm <name> (or delete <name>)
    /alias run <name> [args]
    /alias <name> [args]
    List, inspect, save, remove, or execute session command aliases.
    Declared aliases can also be invoked directly as /<name> [args].
    Example: /alias add changes /diff
    Example: /alias show finish
    """,
    "audit" => "/audit [code|ux]\nAudit the project; omit the focus to audit both code and UX.",
    "audit-thoughts" => "/audit-thoughts\nValidate pipeline item frontmatter and dependencies.",
    "backlog" => "/backlog\nDisplay the idea pipeline map and regenerate its indexes.",
    "bash" => """
    /bash [stats|export|clear|help]
    Show tracked shell-call analytics, export a JSON report, or clear analytics.
    Example: /bash export
    """,
    "checkpoint" =>
      "/checkpoint\nList saved checkpoint IDs, labels, and turns.\n/checkpoint <label>\nSave conversation/provider state (not working-tree files). Example: /checkpoint before-refactor",
    "clear" => "/clear\nClear terminal output without resetting conversation state.",
    "clipboard" => """
    /clipboard (or /cb)
    Copy the latest assistant response to the system clipboard as Markdown.
    /clipboard image (or /clipboard paste, /paste, /paste image)
    Save a clipboard image in .yoke/sessions/assets and send it for analysis.
    """,
    "commit" => "/commit <message>\nCreate a Git commit. Example: /commit Fix parser edge cases",
    "commit-structured" => """
    /commit-structured [files] (or /cpr)
    A declared alias for a structured commit with five PR sections, without a PR.
    Inspect the configured definition with /alias show commit-structured before running.
    """,
    "compact" =>
      "/compact\nCompress context and report estimated current tokens before/after with signed percentage change (not cumulative billed usage).",
    "config" => """
    /config
    /config explorer (or /explorer)
    /config assistant_name <name> (or assistant <name>)
    /config default_branch [<branch>|auto|default] (or branch)
    /config languages [<lang1,lang2...>|auto]
    /config style <starship|extended|compact|minimal>
    /config prompt <template>
    /config toggle <setting_key>
    Show configuration or persist workspace settings in .yoke/config.json.
    Prompt placeholders: {session}, {model}, {mode}, {tasks}.
    Example: /config toggle compact_status_bar
    """,
    "cost" => "/cost\nShow session token usage and estimated cost.",
    "diff" => "/diff [target]\nShow workspace Git changes, optionally against a target revision.",
    "doctor" => "/doctor\nPrint the runtime diagnostic report.",
    "edit" => """
    /edit [path|initial prompt]
    Compose a prompt using $EDITOR or $VISUAL; an existing path opens that file instead.
    Example: /edit lib/example.ex
    """,
    "endpoint" => """
    /endpoint <url|default|deepseek|openrouter|opencode|ollama|lmstudio|vllm>
    Change the generation endpoint. Example: /endpoint ollama
    """,
    "env" => "/env\nShow runtime, workspace, provider, and API-key presence (not its value).",
    "exit" => "/exit (or /quit)\nExit Yoke after background-job and MCP cleanup.",
    "explorer" => "/explorer (or /config explorer)\nOpen the interactive configuration explorer.",
    "export" => """
    /export [markdown|json|lmml|lmmlz]
    Export the active conversation; Markdown is the default.
    Example: /export json
    """,
    "finish" => """
    /finish [files] [--commit-only] (or /pr)
    A declared alias for formatting, a structured commit, and a PR.
    Use --commit-only to omit the PR. Inspect /alias show finish for its configured steps.
    """,
    "git" => "/git <subcommand> [args...]\nRun Git directly. Example: /git status",
    "god" => """
    /god [on|off|status|toggle]
    Automatically answer model questions and confirmations when enabled.
    With no argument, toggle the setting. Example: /god off
    """,
    "help" =>
      "/help [command]\nShow the command menu or contextual help. Example: /help workflow",
    "history" => "/history [search <query>]\nShow recent REPL input or search input history.",
    "import" => """
    /import <path/to/session.lmml|.json> [session_id]
    Import an external session without overwriting an existing one.
    Example: /import saved-session.json imported-session
    """,
    "jobs" => """
    /jobs (or /jobs list)
    /jobs status <id>
    /jobs kill <id>
    /jobs kill all
    List background jobs, inspect their output/status, or terminate running jobs.
    Example: /jobs status job-123
    """,
    "lessons" =>
      "/lessons [add <text>|<text>]\nView or append operational lessons in project/lessons.md.",
    "mcp" => """
    /mcp [list|ls]
    /mcp load
    /mcp add <name> <command> [args...]
    List connected servers, load configured servers, or connect a new MCP process.
    Example: /mcp add tools my-mcp-server --stdio
    """,
    "mode" => """
    /mode local
    /mode remote <node_name>
    /mode docker <container_id>
    Set the Hands execution target, not the generation provider.
    Example: /mode remote worker@host
    """,
    "model" => """
    /model (or /models, /model list, /model ls)
    /model <model_id>
    List models from the active API endpoint or switch the active model.
    Example: /model deepseek-flash
    """,
    "nodes" => "/nodes\nShow the local Erlang node and connected distribution peers.",
    "paste" =>
      "/paste [image]\nSave the clipboard image and send it for analysis; see /help clipboard.",
    "permissions" => """
    /permissions <auto|yolo|ask>
    auto and yolo automatically approve tool calls; ask requires confirmation.
    Example: /permissions ask
    """,
    "plan" => "/plan [on|off|status]\nShow or toggle the plan gate for modifying tool calls.",
    "plugins" =>
      "/plugins [info|reload]\nList registered tools or hot-reload plugins into active actors.",
    "practices" => """
    /practices
    /practices add <text>
    /practices delete (or rm)
    /practices learn <paths...> (or squeeze <paths...>)
    /practices edit
    View, record, remove, learn, or edit language-specific project practices.
    Example: /practices learn ../exemplary-project
    """,
    "process-scrap" =>
      "/process-scrap\nDisplay scrap notes with guidance for turning them into thoughts.",
    "promote" => """
    /promote <slug> [code|initiative] [Must Have|Should Have|Nice to Have]
    Promote a thought to backlog; defaults to code and Should Have.
    Example: /promote refresh-tokens code Must Have
    """,
    "provider" => """
    /provider [local|local-qwen|deepseek]
    Show or switch the generation provider, model, and endpoint together.
    Remote requests send conversation history to the selected provider.
    Example: /provider local
    """,
    "prune-completed" =>
      "/prune-completed\nList completed pipeline items with a knowledge-extraction checklist.",
    "prune-lessons" =>
      "/prune-lessons\nDisplay lessons and guidance for synthesizing durable reference material.",
    "ragex" => """
    /ragex
    /ragex [stats|audit|quality|reindex|help]
    /ragex url <url>
    /ragex export [mermaid|dot|d3]
    Mount workspace code intelligence, inspect/analyze it, or export its graph.
    Export defaults to mermaid. Example: /ragex export dot
    """,
    "reset" =>
      "/reset\nClear conversation history, context tokens, checkpoints, and terminal output.",
    "resume" => """
    /resume [session_id]
    Select a saved conversation interactively, or resume it by ID.
    This resumes a conversation, not a workflow; see /help workflow.
    Example: /resume my-session
    """,
    "review_conversation" => """
    /review_conversation [session_id]
    Aliases: /review-conversation, /conversation [review] [session_id],
    /review conversation [session_id], /session review [session_id].
    Review the current or specified conversation history.
    """,
    "rules" => """
    /rules
    /rules add <scope: text>
    /rules delete (or rm)
    /rules toggle <id>
    View prompt/execution rules, add a scoped rule, select rules to delete, or toggle one.
    Example: /rules add all: Keep changes focused
    """,
    "sandbox" => """
    /sandbox [on|off]
    Restrict file references and tools to the workspace; no argument enables it.
    Example: /sandbox on
    """,
    "scrap" =>
      "/scrap [add <note>|<note>|clear]\nView, append, or clear notes in project/scrap.md.",
    "session" => """
    /session (or /status)
    /session list [all|--all|-a|<limit>]
    /session switch [session_id]
    /session resume [session_id]
    /session review [session_id]
    /session cleanup
    Show active session metadata, list saved sessions (20 by default), switch/resume,
    review a conversation, or delete stale/empty sessions.
    Example: /session list all
    """,
    "skills" => """
    /skills
    /skills <name> [args] (or /skill <name> [args])
    /skills show <name>
    /skills path <name>
    /skills edit <name>
    /skills new <name>
    /skills --global <name>
    List, execute, inspect, edit, or scaffold skills; --global forces the global source.
    Example: /skills show code-review
    """,
    "spar" => """
    /spar [socratic|adversarial] <topic | slug>
    Start a prior-art-backed sparring discussion; defaults to socratic.
    Use the full mode names, not soc/adv. Example: /spar adversarial Token refresh
    """,
    "stats" => "/stats\nDisplay session analytics, execution settings, tools, and token totals.",
    "subagent" =>
      "/subagent <prompt>\nSpawn a background subagent and return immediately; its result is delivered to the parent session when complete.",
    "sweep" =>
      "/sweep <token1> [token2...]\nSearch workflow, reference, lessons, and vault prior art.",
    "thought" => """
    /thought <Title> [| Summary]
    Capture a raw pipeline thought. Example: /thought Token refresh | Renew expired tokens
    """,
    "tokens" => "/tokens\nShow per-turn token usage and the session cumulative total.",
    "undo" =>
      "/undo\nRestore conversation/provider state from the newest checkpoint and show its ID, label, and turn. Working-tree files are unchanged. Use /checkpoint to list snapshots or /checkpoint <label> to save one.",
    "update" => "/update\nRun the Yoke self-update procedure.",
    "what-next" => "/what-next\nRecommend a backlog item or thought to work on next."
  }

  @workflow """
  /workflow — customizable multi-step engineering workflows

  /workflow list
    List workflow names, descriptions, and sources (workspace, global, or bundled).
    Example: /workflow list

  /workflow run <name> [task description]
    Start a new run using the current session's generation provider.
    The remaining text is the task description. It may be omitted, but then
    the run starts with an empty task request.
    Steps may ask for approval, modify files, create branches, run tools, and commit.
    Example: /workflow run elixir Add validation to the signup form

  /workflow status [run-id]
    Without an ID, list persisted runs in this workspace. With an ID, show its
    workflow, status, step, branch, base branch, update time, and halt/failure reason.
    Example: /workflow status
    Example: /workflow status <run-id>

  /workflow resume <run-id>
    Continue a halted or failed run from its saved step using its original
    definition snapshot, not later edits. Completed or aborted runs cannot resume.
    Example: /workflow resume <run-id>

  /workflow abort <run-id>
    Mark a saved run aborted so it cannot be resumed. This does not forcibly
    interrupt synchronous work already in flight or undo changes already made.
    Example: /workflow abort <run-id>

  /workflow init <name> [--from <template>]
    Scaffold .yoke/workflows/definitions/<name>.json without overwriting an
    existing definition. The default and currently bundled template is elixir.
    Edit the JSON steps before running your custom workflow.
    Example: /workflow init team-flow
    Example: /workflow init team-flow --from elixir

  Find a run ID with /workflow status; it is not a conversation/session ID.
  Definitions are resolved workspace first, then ~/.yoke/workflows/definitions/,
  then bundled defaults. Run state is persisted under .yoke/workflows/.
  """

  @doc """
  Returns the menu or help for a command topic, optionally prefixed with `/`.

  Arguments after the command name select the same command documentation.
  No slash command, workflow, shell process, or model request is executed.
  """
  @spec text(String.t()) :: String.t()
  def text(topic \\ "") when is_binary(topic) do
    command =
      topic
      |> String.trim()
      |> String.trim_leading("/")
      |> String.split(~r/\s+/, parts: 2)
      |> List.first()

    command = Map.get(@aliases, command, command)
    help(command)
  end

  defp help(""), do: Formatter.help_menu()
  defp help("guide"), do: Formatter.getting_started_guide()
  defp help("review"), do: Formatter.review_help()
  defp help("linter"), do: Yoke.Linter.help_text()
  defp help("workflow"), do: @workflow

  defp help(command) do
    case Map.fetch(@commands, command) do
      {:ok, documentation} ->
        documentation

      :error ->
        "Unknown help topic '#{command}'. Use /help for available commands, " <>
          "/help workflow for workflow syntax, or /help alias for custom aliases."
    end
  end
end
