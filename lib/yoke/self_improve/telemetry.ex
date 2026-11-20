defmodule Yoke.SelfImprove.Telemetry do
  @moduledoc """
  Records per-turn execution telemetry in `.yoke/telemetry.json` and computes
  empirical model performance scores (UCB1 bandit) per `(phase, language, model)`.
  """

  require Logger

  @telemetry_file ".yoke/telemetry.json"
  @max_entries 500

  @doc "Returns the telemetry store path under `cwd`."
  def telemetry_path(cwd \\ "."), do: Path.join(cwd, @telemetry_file)

  @doc "Loads recorded turn telemetry entries."
  def load(cwd \\ ".") do
    path = telemetry_path(cwd)

    if File.exists?(path) do
      with {:ok, raw} <- File.read(path),
           {:ok, data} when is_list(data) <- Yoke.Json.decode(raw) do
        data
      else
        _ -> []
      end
    else
      []
    end
  end

  @doc "Persists turn telemetry entries (bounded to last #{@max_entries})."
  def save(entries, cwd \\ ".") when is_list(entries) do
    path = telemetry_path(cwd)
    path |> Path.dirname() |> File.mkdir_p!()
    bounded = Enum.take(entries, -@max_entries)

    case Yoke.Json.encode(bounded, pretty: true) do
      {:ok, json} ->
        File.write(path, json)
        {:ok, path}

      {:error, reason} ->
        Logger.warning("[SelfImprove.Telemetry] Failed to encode telemetry: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Records a completed turn's telemetry.

  Expected keys in `attrs` (atom or string):
  - `:session_id`, `:turn_id`, `:model`, `:phase`, `:language`
  - `:tool_calls_count`, `:error_count`, `:loop_hits`, `:tokens`, `:duration_ms`
  - `:outcome` (`:success`, `:failed`, `:undone`, `:cancelled`)
  """
  def record_turn(attrs, cwd \\ ".") when is_map(attrs) do
    entry = %{
      "session_id" => get_attr(attrs, :session_id, "default"),
      "turn_id" => get_attr(attrs, :turn_id, 0),
      "model" => get_attr(attrs, :model, "unknown"),
      "phase" => to_string(get_attr(attrs, :phase, :general)),
      "language" => to_string(get_attr(attrs, :language, "unknown")),
      "tool_calls_count" => get_attr(attrs, :tool_calls_count, 0),
      "error_count" => get_attr(attrs, :error_count, 0),
      "loop_hits" => get_attr(attrs, :loop_hits, 0),
      "undone" => get_attr(attrs, :undone, false),
      "user_corrected" => get_attr(attrs, :user_corrected, false),
      "tokens" => get_attr(attrs, :tokens, 0),
      "duration_ms" => get_attr(attrs, :duration_ms, 0),
      "outcome" => to_string(get_attr(attrs, :outcome, :success)),
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    entries = load(cwd) ++ [entry]
    save(entries, cwd)
    {:ok, entry}
  end

  @doc """
  Marks the most recent turn for `session_id` as `undone: true` and `outcome: "undone"`.
  Called when `/undo` is invoked so model-routing and critic scores learn from rollbacks.
  """
  def mark_last_turn_undone(session_id, cwd \\ ".") do
    entries = load(cwd)

    idx =
      entries
      |> Enum.with_index()
      |> Enum.reverse()
      |> Enum.find_value(fn {e, i} ->
        if e["session_id"] == session_id and not (e["undone"] || false), do: i
      end)

    case idx do
      nil ->
        {:ok, :no_matching_turn}

      i ->
        updated =
          List.update_at(entries, i, fn e ->
            e |> Map.put("undone", true) |> Map.put("outcome", "undone")
          end)

        save(updated, cwd)
        {:ok, Enum.at(updated, i)}
    end
  end

  @doc """
  Computes UCB1-style bandit scores for candidate `models` in `(phase, language)`.
  Returns a list of `%{model: m, score: float, runs: int, success_rate: float, undo_rate: float}`
  sorted descending by `score`.
  """
  def bandit_scores(candidate_models, opts \\ []) when is_list(candidate_models) do
    cwd = Keyword.get(opts, :cwd, ".")
    phase = opts |> Keyword.get(:phase) |> then(&if(&1, do: to_string(&1), else: nil))
    language = opts |> Keyword.get(:language) |> then(&if(&1, do: to_string(&1), else: nil))

    entries =
      load(cwd)
      |> Enum.filter(fn e ->
        (is_nil(phase) or e["phase"] == phase) and
          (is_nil(language) or e["language"] == language)
      end)

    total_runs = max(length(entries), 1)
    by_model = Enum.group_by(entries, & &1["model"])

    candidate_models
    |> Enum.map(fn model ->
      runs = Map.get(by_model, model, [])
      n = length(runs)

      if n == 0 do
        %{model: model, score: 1.0, runs: 0, success_rate: 0.0, undo_rate: 0.0}
      else
        successes =
          Enum.count(runs, &(&1["outcome"] == "success" and not (&1["undone"] || false)))

        undos = Enum.count(runs, &(&1["undone"] || &1["outcome"] == "undone"))
        success_rate = successes / n
        undo_rate = undos / n
        # Penalize undos heavily; add UCB1 exploration bonus
        reward = max(0.0, success_rate - 0.5 * undo_rate)
        explore = :math.sqrt(2.0 * :math.log(total_runs + 1) / n) * 0.25

        %{
          model: model,
          score: Float.round(reward + explore, 4),
          runs: n,
          success_rate: Float.round(success_rate, 3),
          undo_rate: Float.round(undo_rate, 3)
        }
      end
    end)
    |> Enum.sort_by(& &1.score, :desc)
  end

  @doc "Returns aggregated telemetry summary across all recorded turns."
  def summary(cwd \\ ".") do
    entries = load(cwd)
    total = length(entries)

    if total == 0 do
      %{total_turns: 0, by_model: %{}, total_tokens: 0, undo_count: 0, loop_count: 0}
    else
      by_model =
        entries
        |> Enum.group_by(& &1["model"])
        |> Map.new(fn {model, list} ->
          n = length(list)
          ok = Enum.count(list, &(&1["outcome"] == "success"))
          undos = Enum.count(list, &(&1["undone"] || false))

          {model,
           %{
             turns: n,
             success_rate: Float.round(ok / n, 3),
             undo_rate: Float.round(undos / n, 3),
             avg_errors: Float.round(Enum.sum(Enum.map(list, &(&1["error_count"] || 0))) / n, 2)
           }}
        end)

      %{
        total_turns: total,
        by_model: by_model,
        total_tokens: Enum.sum(Enum.map(entries, &(&1["tokens"] || 0))),
        undo_count: Enum.count(entries, &(&1["undone"] || false)),
        loop_count: Enum.sum(Enum.map(entries, &(&1["loop_hits"] || 0)))
      }
    end
  end

  defp get_attr(map, key, default) do
    Map.get(map, key) || Map.get(map, to_string(key)) || default
  end
end
