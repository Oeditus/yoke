defmodule Yoke.SelfImprove.Guardrails do
  @moduledoc """
  Safety, anti-drift, and prompt-budget guardrails for self-improvement.

  Provides:
  1. A staging/quarantine buffer (`.yoke/memory_staging.json`) so newly learned
     rules, lessons, and skills are validated across multiple observations/sessions
     before becoming permanently active.
  2. Hard prompt-token budgeting (`fit_to_budget/2`) so injected memory never
     bloats the system prompt.
  3. Model-switching hysteresis (`can_auto_switch?/2`) to prevent oscillation.
  """

  require Logger

  @staging_file ".yoke/memory_staging.json"
  @default_token_budget 1_500
  @chars_per_token 4
  @default_graduation_observations 2
  @default_switch_cooldown_turns 2

  @type staged_item :: %{
          required(String.t()) => term()
        }

  @doc "Returns the staging buffer file path under `cwd`."
  def staging_path(cwd \\ "."), do: Path.join(cwd, @staging_file)

  @doc "Loads all staged items from `.yoke/memory_staging.json`."
  def load_staging(cwd \\ ".") do
    path = staging_path(cwd)

    if File.exists?(path) do
      with {:ok, raw} <- File.read(path),
           {:ok, items} when is_list(items) <- Yoke.Json.decode(raw) do
        items
      else
        _ -> []
      end
    else
      []
    end
  end

  @doc "Persists staged items to `.yoke/memory_staging.json`."
  def save_staging(items, cwd \\ ".") when is_list(items) do
    path = staging_path(cwd)
    path |> Path.dirname() |> File.mkdir_p!()

    case Yoke.Json.encode(items, pretty: true) do
      {:ok, json} ->
        File.write(path, json)
        {:ok, path}

      {:error, reason} ->
        Logger.warning("[SelfImprove.Guardrails] Failed to encode staging: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Proposes a new self-improvement item into the staging buffer.

  If an item with the same `kind` and `key` already exists, increments its
  `observations` count instead of duplicating it.

  Options:
  - `:cwd` — workspace root (default `"."`)
  - `:key` — deduplication key (defaults to hash of `content`)
  - `:ttl_sessions` — sessions before expiry if unpromoted (default `5`)
  - `:metadata` — arbitrary map
  """
  def propose(kind, content, opts \\ []) when is_binary(content) do
    cwd = Keyword.get(opts, :cwd, ".")
    kind_str = to_string(kind)
    key = Keyword.get(opts, :key) || fingerprint(kind_str <> ":" <> String.trim(content))
    ttl = Keyword.get(opts, :ttl_sessions, 5)
    metadata = Keyword.get(opts, :metadata, %{})
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    items = load_staging(cwd)

    {updated_items, target} =
      case Enum.find_index(items, &(&1["key"] == key and &1["kind"] == kind_str)) do
        nil ->
          item = %{
            "id" => short_id(),
            "kind" => kind_str,
            "key" => key,
            "content" => String.trim(content),
            "status" => "proposed",
            "observations" => 1,
            "undone_hits" => 0,
            "ttl_sessions" => ttl,
            "metadata" => metadata,
            "created_at" => now,
            "updated_at" => now
          }

          {items ++ [item], item}

        idx ->
          item = Enum.at(items, idx)

          updated =
            item
            |> Map.update("observations", 1, &(&1 + 1))
            |> Map.put("updated_at", now)
            |> Map.update("metadata", metadata, &Map.merge(&1 || %{}, metadata))

          {List.replace_at(items, idx, updated), updated}
      end

    case save_staging(updated_items, cwd) do
      {:ok, _} -> {:ok, target}
      err -> err
    end
  end

  @doc "Records a negative `/undo` or rejection signal against a staged item by `id`."
  def record_undo(id, cwd \\ ".") do
    update_item(id, cwd, fn item ->
      item
      |> Map.update("undone_hits", 1, &(&1 + 1))
      |> Map.put("updated_at", DateTime.utc_now() |> DateTime.to_iso8601())
    end)
  end

  @doc "Explicitly promotes a staged item to `active`."
  def promote(id, cwd \\ ".") do
    update_item(id, cwd, fn item ->
      item
      |> Map.put("status", "active")
      |> Map.put("promoted_at", DateTime.utc_now() |> DateTime.to_iso8601())
    end)
  end

  @doc "Explicitly rejects a staged item, preventing re-proposal."
  def reject(id, cwd \\ ".") do
    update_item(id, cwd, fn item ->
      item
      |> Map.put("status", "rejected")
      |> Map.put("rejected_at", DateTime.utc_now() |> DateTime.to_iso8601())
    end)
  end

  @doc """
  Graduates `proposed` items that have reached `min_observations` with zero
  `undone_hits`, and decrements TTL on remaining proposed items (expiring those <= 0).
  Returns `{:ok, %{promoted: [...], expired: [...]}}`.
  """
  def auto_graduate(opts \\ []) do
    cwd = Keyword.get(opts, :cwd, ".")
    min_obs = Keyword.get(opts, :min_observations, @default_graduation_observations)
    now = DateTime.utc_now() |> DateTime.to_iso8601()
    items = load_staging(cwd)

    {updated, promoted, expired} =
      Enum.reduce(items, {[], [], []}, fn item, {acc, prom, exp} ->
        case item["status"] do
          "proposed" ->
            obs = item["observations"] || 0
            undone = item["undone_hits"] || 0
            ttl = (item["ttl_sessions"] || 1) - 1

            cond do
              obs >= min_obs and undone == 0 ->
                p = item |> Map.put("status", "active") |> Map.put("promoted_at", now)
                {acc ++ [p], prom ++ [p], exp}

              ttl <= 0 or undone >= 2 ->
                e = item |> Map.put("status", "expired") |> Map.put("updated_at", now)
                {acc ++ [e], prom, exp ++ [e]}

              true ->
                kept = item |> Map.put("ttl_sessions", ttl) |> Map.put("updated_at", now)
                {acc ++ [kept], prom, exp}
            end

          _ ->
            {acc ++ [item], prom, exp}
        end
      end)

    case save_staging(updated, cwd) do
      {:ok, _} -> {:ok, %{promoted: promoted, expired: expired}}
      err -> err
    end
  end

  @doc ~S|Lists staged items, optionally filtered by status (`"proposed"`, `"active"`, `"rejected"`).|
  def list_staged(cwd \\ ".", status \\ nil) do
    items = load_staging(cwd)

    if status do
      status_str = to_string(status)
      Enum.filter(items, &(&1["status"] == status_str))
    else
      items
    end
  end

  @doc """
  Fits weighted memory entries into a hard prompt token budget.

  Each entry is a map with `:text` (or `"text"`) and optional `:score` (float,
  combining recency & helpfulness). Entries are sorted descending by `:score`
  and greedily packed until `max_tokens` (approx 4 chars/token) is reached.
  """
  def fit_to_budget(entries, opts \\ []) when is_list(entries) do
    max_tokens = Keyword.get(opts, :max_tokens, @default_token_budget)
    max_chars = max_tokens * @chars_per_token

    entries
    |> Enum.map(fn entry ->
      text = Map.get(entry, :text) || Map.get(entry, "text") || ""
      score = Map.get(entry, :score) || Map.get(entry, "score") || 1.0
      %{entry: entry, text: text, score: score, chars: String.length(text)}
    end)
    |> Enum.reject(&(&1.text == ""))
    |> Enum.sort_by(& &1.score, :desc)
    |> Enum.reduce_while({[], 0}, fn item, {acc, used} ->
      separator_cost = if acc == [], do: 0, else: 2
      next_used = used + item.chars + separator_cost

      if next_used <= max_chars do
        {:cont, {acc ++ [item.entry], next_used}}
      else
        {:halt, {acc, used}}
      end
    end)
    |> elem(0)
  end

  @doc "Estimates token count for a binary string using 4 chars/token heuristic."
  def estimate_tokens(text) when is_binary(text) do
    div(String.length(text) + @chars_per_token - 1, @chars_per_token)
  end

  @doc """
  Model-switching hysteresis check.
  Prevents automatic model switching more than once every `cooldown_turns` turns.
  """
  def can_auto_switch?(current_turn, last_switch_turn, opts \\ [])
      when is_integer(current_turn) do
    cooldown = Keyword.get(opts, :cooldown_turns, @default_switch_cooldown_turns)

    case last_switch_turn do
      nil -> true
      turn when is_integer(turn) -> current_turn - turn >= cooldown
      _ -> true
    end
  end

  defp update_item(id, cwd, fun) do
    items = load_staging(cwd)

    case Enum.find_index(items, &(&1["id"] == id)) do
      nil ->
        {:error, :not_found}

      idx ->
        updated_item = fun.(Enum.at(items, idx))
        updated_items = List.replace_at(items, idx, updated_item)

        case save_staging(updated_items, cwd) do
          {:ok, _} -> {:ok, updated_item}
          err -> err
        end
    end
  end

  defp fingerprint(text) do
    :crypto.hash(:sha256, text) |> Base.encode16(case: :lower) |> binary_part(0, 16)
  end

  defp short_id do
    :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
  end
end
