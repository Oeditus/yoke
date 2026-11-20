defmodule Yoke.SelfImprove.Decay do
  @moduledoc """
  Staleness tracking and helpfulness decay for learned memories (`Episodes`, `Lessons`, `Rules`).

  Uses `Yoke.StalenessTracker` to detect when files referenced by an episode
  have changed, and prunes stale/unhelpful episodes so old assumptions do not
  poison future sessions.
  """

  alias Yoke.SelfImprove.Episodes
  alias Yoke.StalenessTracker

  @doc "Tags an episode or memory resource ID with the current SHA-256 fingerprint of `files`."
  def tag_files(resource_id, files, cwd \\ ".") when is_list(files) do
    StalenessTracker.record_fingerprint("mem:" <> to_string(resource_id), files, cwd: cwd)
  end

  @doc "Returns true if the files associated with `resource_id` have drifted since tagging."
  def stale?(resource_id, files, cwd \\ ".") when is_list(files) do
    StalenessTracker.stale?("mem:" <> to_string(resource_id), files, cwd: cwd)
  end

  @doc """
  Scans stored episodes in `.yoke/episodes.jsonl`, checks file fingerprints when
  present, and prunes episodes whose referenced files changed AND have low hits (`<= 1`).
  Returns `{:ok, %{kept: int, pruned: int}}`.
  """
  def prune_stale_episodes(cwd \\ ".") do
    episodes = Episodes.load(cwd)

    {kept, pruned} =
      Enum.split_with(episodes, fn ep ->
        files = ep["fingerprint"] && ep["files"]

        if is_list(files) and files != [] do
          current_fp = StalenessTracker.compute_fingerprint(files)
          unchanged? = current_fp == ep["fingerprint"]
          unchanged? or (ep["hits"] || 1) >= 3
        else
          true
        end
      end)

    if pruned != [] do
      Episodes.save(kept, cwd)
    end

    {:ok, %{kept: length(kept), pruned: length(pruned)}}
  end
end
