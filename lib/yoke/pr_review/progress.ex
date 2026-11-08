defmodule Yoke.PRReview.Progress do
  @moduledoc """
  Tracks whether revision-pinned reads provide new evidence during a review.
  Unlike exact-call cycle detection, changing a range or an ignored argument
  cannot disguise repeated results from the same immutable source.
  """

  @stalled_steps 3

  def new, do: %{seen: MapSet.new(), stalled_steps: 0}

  def observe(progress, calls, messages, cwd) do
    results = Map.new(messages, &{&1["tool_call_id"], &1["content"]})

    fingerprints =
      calls
      |> Enum.filter(&(&1.name in ["read_file", "read_files"]))
      |> Enum.flat_map(fn call ->
        case Map.fetch(results, call.id) do
          {:ok, content} ->
            source = source(call, cwd)
            [:crypto.hash(:sha256, :erlang.term_to_binary({source, content}))]

          :error ->
            []
        end
      end)
      |> MapSet.new()

    novel = MapSet.difference(fingerprints, progress.seen)

    stalled_steps =
      if MapSet.size(fingerprints) > 0 and MapSet.size(novel) == 0 and
           Enum.all?(calls, &(&1.name in ["read_file", "read_files"])) do
        progress.stalled_steps + 1
      else
        0
      end

    updated = %{
      seen: MapSet.union(progress.seen, fingerprints),
      stalled_steps: stalled_steps
    }

    if stalled_steps >= @stalled_steps, do: {:stalled, updated}, else: {:ok, updated}
  end

  defp source(call, cwd) do
    paths =
      case {call.name, call.arguments["paths"]} do
        {"read_file", _} -> [call.arguments["path"]]
        {"read_files", paths} when is_list(paths) -> paths
        {"read_files", invalid} -> [invalid]
      end

    paths =
      Enum.map(paths, fn
        path when is_binary(path) -> Path.expand(path, cwd)
        path -> path
      end)

    {call.name, paths, Map.get(call.arguments, "revision", "head")}
  end
end
