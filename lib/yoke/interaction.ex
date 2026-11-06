defmodule Yoke.Interaction do
  @moduledoc """
  The blocking seam: every place where a running agent turn would otherwise
  stop and wait for a human is routed through this behaviour.

  Two implementations ship with Yoke:

    * `Yoke.Interaction.TTY` -- the interactive REPL experience. It wraps
      `Yoke.CLI.Spinner.with_paused/1` plus `Yoke.CLI.QuestionPrompt`, so
      behaviour is byte-identical to the pre-seam code.

    * `Yoke.Interaction.Policy` -- headless (CI) operation. It never blocks
      and never asks; it answers immediately from a declarative policy
      document (`.yoke/policy.json` or the `YOKE_POLICY` env var).

  The implementation is selected **once** at startup via
  `Application.get_env(:yoke, :interaction, Yoke.Interaction.TTY)`, so call
  sites never branch per call -- they simply call `ask/2` and pattern-match
  the returned decision.

  ## Kinds

  | kind | Raised when | TTY default selection |
  | :--- | :--- | :--- |
  | `:plan_gate` | A non-trivial batch of tool calls needs plan approval | first option |
  | `:plan_revision` | The user asked for plan changes and must supply feedback | deny |
  | `:loop_break` | The agent is stuck repeating the same tool cycle | stop (deny) |
  | `:api_error` | The provider failed after all retries | stop (deny) |
  | `:max_depth` | The agent loop hit its max tool-iteration depth | stop (deny) |
  | `:tool_permission` | A tool call needs explicit user confirmation | deny |
  | `:review_fix` | A review turn wants to apply fixes / record patterns | deny |

  ## Decisions

  A decision is one of:

    * `:approve` -- proceed (approve the plan, allow the tool, retry, continue).
    * `:deny` -- stop the turn (or refuse the tool) without further prompting.
    * `{:answer, text}` -- proceed with the human's free-form text as an
      amendment (used by `:plan_revision`).
  """

  @typedoc "The category of interaction being requested."
  @type kind ::
          :plan_gate
          | :plan_revision
          | :loop_break
          | :api_error
          | :max_depth
          | :tool_permission
          | :review_fix
          | :workflow_confirm
          | :lint_fix

  @typedoc "The answer to an interaction request."
  @type decision :: :approve | :deny | {:answer, String.t()}

  @typedoc """
  Context handed to the implementation.

  Common keys:

    * `:question` -- the human-readable question (already rendered Markdown
      is fine; TTY renders it, Policy ignores it).
    * `:options` -- the ordered list of selectable options (TTY only).

  Kind-specific keys are documented on each call site in
  `Yoke.Brain.Session`; implementations must tolerate unknown keys.
  """
  @type context :: map()

  @doc """
  Asks for a decision of the given `kind`.

  Implementations must be total: they always return a `t:decision/0` and
  never raise for a well-formed context.
  """
  @callback ask(kind(), context()) :: decision()

  @doc "Returns the configured interaction implementation module."
  @spec impl() :: module()
  def impl do
    Application.get_env(:yoke, :interaction, Yoke.Interaction.TTY)
  end

  @doc """
  Asks the configured implementation for a decision.

  This is the only entry point call sites should use; it performs the single
  module lookup so no call site branches on the backend.
  """
  @spec ask(kind(), context()) :: decision()
  def ask(kind, context \\ %{}) do
    impl().ask(kind, context)
  end

  @doc "All kinds this behaviour defines, in a stable order."
  @spec kinds() :: [kind()]
  def kinds do
    [
      :plan_gate,
      :plan_revision,
      :loop_break,
      :api_error,
      :max_depth,
      :tool_permission,
      :review_fix,
      :workflow_confirm,
      :lint_fix
    ]
  end
end
