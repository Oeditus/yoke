defmodule Yoke.PRReview.ReviewDismissal do
  @moduledoc false

  alias Yoke.Json
  alias Yoke.PRReview.Context

  @marker "<!-- yoke:code-review:v1 -->"

  def marker, do: @marker

  # Use identity from the posted review, not /user: installation tokens do not
  # support that endpoint. Review IDs also protect newer concurrent reviews.
  def dismiss(context, %{review_id: id, reviewer_id: reviewer_id})
      when is_integer(id) and is_integer(reviewer_id) do
    endpoint = "repos/#{context.repository}/pulls/#{context.pr_number}/reviews"

    with {:ok, reviews} <- list_reviews(endpoint, context.cwd) do
      reviews
      |> Enum.filter(&superseded?(&1, id, reviewer_id))
      |> Enum.reduce_while(:ok, fn review, :ok ->
        with :ok <- Context.verify_current(context),
             :ok <- dismiss_review(endpoint, review["id"], context.cwd) do
          {:cont, :ok}
        else
          {:error, _} = error -> {:halt, error}
        end
      end)
    end
  end

  def dismiss(_context, _result) do
    {:error,
     "Clean review posted, but GitHub returned no review identity; previous Yoke change requests were not dismissed."}
  end

  defp superseded?(review, current_id, reviewer_id) do
    id = review["id"]
    body = review["body"] || ""

    is_integer(id) and id < current_id and
      review["state"] == "CHANGES_REQUESTED" and
      get_in(review, ["user", "id"]) == reviewer_id and
      (String.contains?(body, @marker) or legacy_review?(body))
  end

  defp legacy_review?(body) do
    String.starts_with?(body, "## \u{1FAA2} Review from ") and
      String.contains?(body, "**Code review: Changes requested**") and
      String.contains?(body, "There are some comments left. Please address the reported issues.")
  end

  defp list_reviews(endpoint, cwd) do
    case System.cmd("gh", ["api", "#{endpoint}?per_page=100", "--paginate", "--slurp"],
           cd: cwd,
           stderr_to_stdout: true
         ) do
      {out, 0} ->
        case Json.decode(out) do
          {:ok, pages} when is_list(pages) ->
            if Enum.all?(pages, &(is_list(&1) and Enum.all?(&1, fn r -> is_map(r) end))) do
              {:ok, Enum.concat(pages)}
            else
              {:error,
               "Could not parse GitHub review pages; previous Yoke change requests remain."}
            end

          _ ->
            {:error, "Could not parse GitHub review pages; previous Yoke change requests remain."}
        end

      {out, _} ->
        {:error, "Could not list previous Yoke reviews: #{String.trim(out)}"}
    end
  end

  defp dismiss_review(endpoint, id, cwd) do
    args = [
      "api",
      "-X",
      "PUT",
      "#{endpoint}/#{id}/dismissals",
      "-f",
      "message=Superseded by a successful Yoke review with no actionable issues."
    ]

    case System.cmd("gh", args, cd: cwd, stderr_to_stdout: true) do
      {_, 0} -> :ok
      {out, _} -> {:error, "Could not dismiss Yoke review #{id}: #{String.trim(out)}"}
    end
  end
end
