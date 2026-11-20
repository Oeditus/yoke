defmodule Yoke.SelfImprove.Episodes do
  @moduledoc """
  Episodic error-fix memory (`.yoke/episodes.jsonl`).

  Automatically captures `(error_signature -> root_cause / fix_action)` tuples
  when a turn encounters a tool/compiler/test error and subsequently resolves it,
  retrieves top-K relevant episodes on demand, and proposes candidate practices
  via `Guardrails.propose/3` once a pattern recurs 3+ times.
  """

  alias Yoke.SelfImprove.Guardrails
  alias Yoke.StalenessTracker

  @episodes_file ".yoke/episodes.jsonl"
  @max_episodes 300
  @crystallize_threshold 3

  @doc "Returns the path to `.yoke/episodes.jsonl`."
  def episodes_path(cwd \\ "."), do: Path.join(cwd, @episodes_file)

  @doc "Loads all stored episodes from `.yoke/episodes.jsonl`."
  def load(cwd \\ ".") do
    path = episodes_path(cwd)

    if File.exists?(path) do
      path
      |> File.stream!()
      |> Stream.map(&String.trim/1)
      |> Stream.reject(&(&1 == ""))
      |> Enum.reduce([], fn line, acc ->
        case Yoke.Json.decode(line) do
          {:ok, %{} = ep} -> acc ++ [ep]
          _ -> acc
        end
      end)
    else
      []
    end
  end

  @doc "Saves episodes list to `.yoke/episodes.jsonl` (bounded to #{@max_episodes})."
  def save(episodes, cwd \\ ".") when is_list(episodes) do
    path = episodes_path(cwd)
    path |> Path.dirname() |> File.mkdir_p!()
    bounded = Enum.take(episodes, -@max_episodes)

    lines =
      Enum.map_join(bounded, "\n", fn ep ->
        case Yoke.Json.encode(ep) do
          {:ok, json} -> json
          _ -> "{}"
        end
      end)

    content = if lines == "", do: "", else: lines <> "\n"
    File.write!(path, content)
    {:ok, path}
  end

  @doc """
  Records or increments an `(error_signature, fix_pattern)` episode.
  If `hits >= #{@crystallize_threshold}`, proposes a candidate practice into `Guardrails`.
  """
  def record_episode(attrs, cwd \\ ".") when is_map(attrs) do
    error_text = Map.get(attrs, :error) || Map.get(attrs, "error") || ""
    fix_text = Map.get(attrs, :fix) || Map.get(attrs, "fix") || ""
    files = Map.get(attrs, :files) || Map.get(attrs, "files") || []

    sig = normalize_signature(error_text)
    now = DateTime.utc_now() |> DateTime.to_iso8601()
    fingerprint = if files != [], do: StalenessTracker.compute_fingerprint(files), else: nil

    episodes = load(cwd)

    {updated, target} =
      case Enum.find_index(episodes, &(&1["signature"] == sig)) do
        nil ->
          ep = %{
            "id" => short_id(),
            "signature" => sig,
            "raw_error" => String.slice(String.trim(error_text), 0, 400),
            "fix" => String.slice(String.trim(fix_text), 0, 400),
            "files" => files,
            "fingerprint" => fingerprint,
            "hits" => 1,
            "helpful_count" => 1,
            "created_at" => now,
            "updated_at" => now
          }

          {episodes ++ [ep], ep}

        idx ->
          ep = Enum.at(episodes, idx)

          up =
            ep
            |> Map.update("hits", 1, &(&1 + 1))
            |> Map.put("fix", String.slice(String.trim(fix_text), 0, 400))
            |> Map.put("updated_at", now)
            |> then(fn m ->
              if fingerprint, do: Map.put(m, "fingerprint", fingerprint), else: m
            end)

          {List.replace_at(episodes, idx, up), up}
      end

    save(updated, cwd)

    if (target["hits"] || 0) >= @crystallize_threshold do
      Guardrails.propose(
        :practice,
        "When seeing `#{target["signature"]}`, apply fix: #{target["fix"]}",
        cwd: cwd,
        key: "ep_" <> fingerprint_str(target["signature"]),
        metadata: %{"source" => "episodes", "hits" => target["hits"]}
      )
    end

    {:ok, target}
  end

  @doc """
  Scans a sequence of turn messages (`role: "assistant"` / `role: "tool"`) for
  an error followed by a successful tool/edit action, and captures it as an episode.
  """
  def capture_from_messages(messages, cwd \\ ".") when is_list(messages) do
    tool_events =
      Enum.flat_map(messages, fn
        %{"role" => "tool", "content" => content} = msg when is_binary(content) ->
          [%{name: msg["name"] || "tool", content: content, error?: error_output?(content)}]

        _ ->
          []
      end)

    capture_transitions(tool_events, cwd, [])
  end

  defp capture_transitions([], _cwd, acc), do: Enum.reverse(acc)

  defp capture_transitions([%{error?: true, content: err} | rest], cwd, acc) do
    case Enum.find(rest, &(not &1.error?)) do
      nil ->
        capture_transitions(rest, cwd, acc)

      %{name: fix_tool, content: fix_out} ->
        fix_summary = "#{fix_tool}: #{String.slice(String.trim(fix_out), 0, 160)}"
        {:ok, ep} = record_episode(%{error: err, fix: fix_summary}, cwd)
        capture_transitions(rest, cwd, [ep | acc])
    end
  end

  defp capture_transitions([_ | rest], cwd, acc), do: capture_transitions(rest, cwd, acc)

  @doc """
  Retrieves top-K matching episodes for `query` (e.g. current prompt or error text),
  scored by keyword overlap and hit count.
  """
  def retrieve(query, opts \\ []) when is_binary(query) do
    cwd = Keyword.get(opts, :cwd, ".")
    k = Keyword.get(opts, :k, 2)
    q_tokens = tokenize(query)

    if MapSet.size(q_tokens) == 0 do
      []
    else
      load(cwd)
      |> Enum.map(fn ep ->
        ep_tokens = tokenize((ep["signature"] || "") <> " " <> (ep["raw_error"] || ""))
        overlap = MapSet.intersection(q_tokens, ep_tokens) |> MapSet.size()
        union = max(MapSet.union(q_tokens, ep_tokens) |> MapSet.size(), 1)
        jaccard = overlap / union
        bonus = min((ep["hits"] || 1) * 0.05, 0.25)
        {ep, jaccard + bonus, overlap}
      end)
      |> Enum.filter(fn {_ep, _score, overlap} -> overlap > 0 end)
      |> Enum.sort_by(&elem(&1, 1), :desc)
      |> Enum.take(k)
      |> Enum.map(&elem(&1, 0))
    end
  end

  @doc "Formats retrieved episodes into a compact prompt preamble within `max_tokens`."
  def build_preamble(query, opts \\ []) when is_binary(query) do
    max_tokens = Keyword.get(opts, :max_tokens, 400)
    episodes = retrieve(query, opts)

    if episodes == [] do
      ""
    else
      entries =
        Enum.map(episodes, fn ep ->
          %{
            text: "- Error `#{ep["signature"]}` → Fix: #{ep["fix"]} (seen #{ep["hits"]}x)",
            score: (ep["hits"] || 1) * 1.0
          }
        end)

      kept = Guardrails.fit_to_budget(entries, max_tokens: max_tokens)

      if kept == [] do
        ""
      else
        body = Enum.map_join(kept, "\n", & &1.text)

        "\n### Relevant Past Error-Fix Episodes\n#{body}\n"
      end
    end
  end

  @doc "Normalizes an error string into a stable signature by stripping volatile numbers/hashes."
  def normalize_signature(text) when is_binary(text) do
    text
    |> String.split("\n")
    |> Enum.take(2)
    |> Enum.join(" ")
    |> String.replace(~r/:\d+(:\d+)?/, ":<line>")
    |> String.replace(~r/\b[0-9a-f]{7,40}\b/i, "<hash>")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> String.slice(0, 140)
  end

  defp error_output?(content) do
    Regex.match?(
      ~r/\b(error|exception|failed|enoent|undefined|syntaxerror|compileerror|mismatch)\b/i,
      content
    )
  end

  defp tokenize(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^\w\s]/, " ")
    |> String.split(~r/\s+/, trim: true)
    |> Enum.reject(&(String.length(&1) < 3))
    |> MapSet.new()
  end

  defp fingerprint_str(s) do
    :crypto.hash(:sha256, s) |> Base.encode16(case: :lower) |> binary_part(0, 12)
  end

  defp short_id, do: :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
end
