defmodule Yoke.PRReview.CLI do
  @moduledoc """
  Interactive review-fix confirmation, turn rendering, and pattern recording.

  Permission decisions go through `Yoke.Interaction`, so these flows remain
  usable with headless policies as well as the terminal.
  """

  alias Yoke.Brain.Session
  alias Yoke.CLI.Formatter
  alias Yoke.PRReview.Context

  @doc "Offer to apply fixes, revalidating the pinned checkout after confirmation."
  def handle_review_fixes(session_pid, ctx, fix_prompt) do
    IO.puts("\nYoke Code Review Fix Prompt:\n" <> fix_prompt)

    with :ok <- Context.verify_fix_checkout(ctx),
         true <-
           review_yes?(
             "Would you like Yoke to examine and apply these fixes now?",
             ["No, I will apply them later (Recommended)", "Yes, apply fixes now"],
             ctx
           ),
         :ok <- Context.verify_fix_checkout(ctx) do
      prompt = "Repository: #{ctx.cwd}\nReviewed head: #{ctx.head_sha}\n\n" <> fix_prompt

      run_review_turn(
        session_pid,
        fn -> Session.apply_review_fixes(session_pid, ctx, prompt) end,
        "Applying Code Review fixes… (Ctrl+Q to interrupt)"
      )
      |> print_review_result()
    else
      false -> :ok
      {:error, error} -> IO.puts(Formatter.format_warning(error))
    end
  end

  @doc "Offer to record accepted actionable findings in the reviewed repository."
  def maybe_record_review_patterns(findings, ctx) do
    options = ["No, skip pattern update (Recommended)", "Yes, update living review patterns"]

    if review_yes?("Record accepted findings in .yoke/review_patterns.md?", options, ctx) do
      reference = if ctx.pr_number, do: "PR ##{ctx.pr_number}", else: "Commit #{ctx.head_sha}"
      Enum.each(findings, &Yoke.PRReview.Patterns.record_finding(&1, reference, ctx.cwd))

      IO.puts(
        Formatter.format_success("Updated living review patterns in .yoke/review_patterns.md")
      )
    end
  end

  defp review_yes?(question, options, ctx) do
    Yoke.Interaction.ask(:review_fix, %{question: question, options: options, cwd: ctx.cwd}) ==
      :approve
  end

  @doc "Run a review turn with terminal progress and cancellation support."
  def run_review_turn(session_pid, fun, title) do
    Yoke.CLI.Spinner.run(fn -> Yoke.CLI.Interrupt.run(session_pid, fun) end, title: title)
  end

  @doc "Render the result of a review turn."
  def print_review_result({:ok, %{content: content}}) do
    IO.puts("\n" <> Formatter.format_agent_response(content) <> "\n")
    Formatter.flush()
  end

  def print_review_result({:error, error}) do
    IO.puts(Formatter.format_error(error))
    Formatter.flush()
  end
end
