defmodule Yoke.Interaction.TTY do
  @moduledoc """
  The interactive implementation of `Yoke.Interaction`.

  This module is a thin adapter: it performs exactly the same
  `Yoke.CLI.Spinner.with_paused/1` + `Yoke.CLI.QuestionPrompt` calls the
  pre-seam code performed inline, and maps the modal's answer back onto the
  `t:Yoke.Interaction.decision/0` vocabulary. REPL behaviour is therefore
  byte-identical to before the seam existed.

  Every `ask/2` here is *blocking* and requires a human. In a headless
  environment (CI, piped stdin) `Yoke.CLI.QuestionPrompt` already degrades to
  its non-TTY fallback and reads from stdin; if stdin is closed, `IO.gets/1`
  returns `:eof`, which this module maps to `:deny` (fail closed).
  """

  @behaviour Yoke.Interaction

  alias Yoke.CLI.QuestionPrompt
  alias Yoke.CLI.Spinner

  @impl true
  def ask(kind, context \\ %{})

  def ask(:plan_gate, context) do
    options = Map.get(context, :options, ["Approve & execute", "Request changes", "Deny"])

    answer =
      Spinner.with_paused(fn ->
        QuestionPrompt.ask_single_question(Map.get(context, :question, ""), options, false)
      end)

    case answer do
      %{selected: [selection]} -> classify_plan_selection(selection)
      %{custom: custom} when is_binary(custom) and custom != "" -> {:answer, custom}
      _ -> :deny
    end
  end

  def ask(:plan_revision, context) do
    options = Map.get(context, :options, ["Approve as-is anyway", "Deny"])

    answer =
      Spinner.with_paused(fn ->
        QuestionPrompt.ask_single_question(
          Map.get(context, :question, "Approved plan needs changes. What should change?"),
          options,
          false
        )
      end)

    case answer do
      %{custom: text} when is_binary(text) and text != "" -> {:answer, text}
      %{selected: [selection]} -> classify_approve_or_deny(selection)
      _ -> :deny
    end
  end

  def ask(:tool_permission, context) do
    options =
      Map.get(context, :options, [
        "Allow once",
        "Allow always for this session",
        "Allow always (save to project config)",
        "Allow always (save to global config)",
        "Deny tool execution",
        "Deny always (save to project config)",
        "Deny always (save to global config)"
      ])

    answer =
      Spinner.with_paused(fn ->
        QuestionPrompt.ask_single_question(Map.get(context, :question, ""), options, false)
      end)

    case answer do
      %{selected: [selection]} -> classify_tool_permission(selection)
      _ -> :deny
    end
  end

  def ask(:max_depth, context) do
    options =
      Map.get(context, :options, [
        "Continue execution (#{Map.get(context, :extra_iterations, 0)} more iterations)",
        "Stop turn here"
      ])

    answer =
      Spinner.with_paused(fn ->
        QuestionPrompt.ask_single_question(Map.get(context, :question, ""), options, false)
      end)

    case answer do
      %{selected: [selection]} -> classify_continue_or_stop(selection)
      _ -> :deny
    end
  end

  def ask(:api_error, context) do
    options = Map.get(context, :options, ["Retry API call", "Stop turn here"])

    answer =
      Spinner.with_paused(fn ->
        QuestionPrompt.ask_single_question(Map.get(context, :question, ""), options, false)
      end)

    case answer do
      %{selected: [selection]} -> classify_retry_or_stop(selection)
      _ -> :deny
    end
  end

  def ask(:loop_break, context) do
    options =
      Map.get(context, :options, [
        "Stop turn here (break loop)",
        "Force model to summarize without tools"
      ])

    answer =
      Spinner.with_paused(fn ->
        QuestionPrompt.ask_single_question(Map.get(context, :question, ""), options, false)
      end)

    case answer do
      %{selected: [selection]} -> classify_loop_choice(selection)
      _ -> :deny
    end
  end

  def ask(:review_fix, context) do
    options = Map.get(context, :options, ["No, skip (Recommended)", "Yes"])

    answer =
      Spinner.with_paused(fn ->
        QuestionPrompt.ask_single_question(Map.get(context, :question, ""), options, false)
      end)

    case answer do
      %{selected: [selection]} -> classify_yes_no(selection)
      %{custom: custom} when is_binary(custom) -> classify_yes_no(custom)
      _ -> :deny
    end
  end

  def ask(_kind, _context), do: :deny

  # The classification helpers below are the exact predicates the pre-seam
  # call sites used inline, so their behaviour (including which substrings
  # they match) is preserved verbatim.

  @doc "Maps a plan-gate selection onto approve / revise / deny."
  @spec classify_plan_selection(String.t()) :: Yoke.Interaction.decision()
  def classify_plan_selection(selection) when is_binary(selection) do
    case Yoke.PlanGate.decision_from_selection(selection) do
      :approve -> :approve
      :request_changes -> {:answer, selection}
      _ -> :deny
    end
  end

  @doc ~S|Maps an "Approve as-is anyway" / "Deny" revision selection.|
  @spec classify_approve_or_deny(String.t()) :: Yoke.Interaction.decision()
  def classify_approve_or_deny(selection) when is_binary(selection) do
    if String.starts_with?(selection, "Approve"), do: :approve, else: :deny
  end

  @doc ~S|Maps a max-tool-depth "Continue" / "Stop" selection.|
  @spec classify_continue_or_stop(String.t()) :: Yoke.Interaction.decision()
  def classify_continue_or_stop(selection) when is_binary(selection) do
    if String.contains?(selection, "Continue"), do: :approve, else: :deny
  end

  @doc ~S|Maps an API-error "Retry" / "Stop" selection.|
  @spec classify_retry_or_stop(String.t()) :: Yoke.Interaction.decision()
  def classify_retry_or_stop(selection) when is_binary(selection) do
    if String.contains?(selection, "Retry"), do: :approve, else: :deny
  end

  @doc ~S|Maps a loop-break "Force model to summarize" / "Stop" selection.|
  @spec classify_loop_choice(String.t()) :: Yoke.Interaction.decision()
  def classify_loop_choice(selection) when is_binary(selection) do
    if String.contains?(selection, "Force model"), do: :approve, else: :deny
  end

  @doc ~S|Maps a yes/no selection ("Yes..." approves, anything else denies).|
  @spec classify_yes_no(String.t()) :: Yoke.Interaction.decision()
  def classify_yes_no(selection) when is_binary(selection) do
    if String.starts_with?(selection, "Yes"), do: :approve, else: :deny
  end

  @doc """
  Classifies a tool-permission modal selection.

  Returns `{:allow, persistence}` where `persistence` is `:once`, `:session`,
  `:project`, or `:global`; or `{:deny, persistence}` with the same
  persistence vocabulary. Exposed (rather than private) because
  `Yoke.Brain.Session` needs the persistence level to decide whether to write
  the choice into project/global config.
  """
  @spec classify_tool_permission(String.t()) :: {:allow | :deny, atom()}
  def classify_tool_permission(selection) when is_binary(selection) do
    down = String.downcase(selection)
    allow? = String.contains?(down, "allow")

    persistence =
      cond do
        String.contains?(down, "global") -> :global
        String.contains?(down, "project") -> :project
        String.contains?(down, "session") -> :session
        true -> :once
      end

    if allow?, do: {:allow, persistence}, else: {:deny, persistence}
  end
end
