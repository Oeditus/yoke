defmodule Yoke.SelfImprove.SkillSynthesizer do
  @moduledoc """
  Detects repeated multi-step tool-call workflows across turns and synthesizes
  reusable `SKILL.md` drafts under `.yoke/skills/auto_<slug>/SKILL.md`
  (compatible with `Yoke.Skill.Manager`).
  """

  alias Yoke.SelfImprove.Guardrails

  @seq_file ".yoke/workflows_observed.json"
  @min_seq_len 3
  @max_seq_len 5
  @synthesize_threshold 3

  @doc "Returns `.yoke/workflows_observed.json` path."
  def sequences_path(cwd \\ "."), do: Path.join(cwd, @seq_file)

  @doc "Loads observed tool-sequence counts."
  def load_sequences(cwd \\ ".") do
    path = sequences_path(cwd)

    if File.exists?(path) do
      with {:ok, raw} <- File.read(path),
           {:ok, map} when is_map(map) <- Yoke.Json.decode(raw) do
        map
      else
        _ -> %{}
      end
    else
      %{}
    end
  end

  @doc """
  Records a turn's ordered list of tool names. If any contiguous n-gram
  (length #{@min_seq_len}..#{@max_seq_len}) reaches #{@synthesize_threshold}
  occurrences, synthesizes a `SKILL.md` draft and proposes it in `Guardrails`.
  Returns `{:ok, synthesized_paths}`.
  """
  def observe_sequence(tool_names, cwd \\ ".") when is_list(tool_names) do
    cleaned = Enum.map(tool_names, &to_string/1)

    if length(cleaned) < @min_seq_len do
      {:ok, []}
    else
      ngrams = extract_ngrams(cleaned, @min_seq_len, @max_seq_len)
      counts = load_sequences(cwd)

      {updated, triggered} =
        Enum.reduce(ngrams, {counts, []}, fn seq, {acc, trig} ->
          key = Enum.join(seq, " -> ")
          next_count = (acc[key] || 0) + 1
          acc2 = Map.put(acc, key, next_count)

          if next_count == @synthesize_threshold do
            {acc2, [seq | trig]}
          else
            {acc2, trig}
          end
        end)

      save_sequences(updated, cwd)

      synthesized =
        Enum.map(Enum.reverse(triggered), fn seq ->
          {:ok, path} = write_skill_draft(seq, cwd)
          path
        end)

      {:ok, synthesized}
    end
  end

  @doc "Writes a `SKILL.md` draft for `tool_seq` and stages it in `Guardrails`."
  def write_skill_draft(tool_seq, cwd \\ ".") when is_list(tool_seq) do
    slug =
      "auto_" <>
        (:crypto.hash(:sha256, Enum.join(tool_seq, "|"))
         |> Base.encode16(case: :lower)
         |> binary_part(0, 8))

    dir = Path.join([cwd, ".yoke", "skills", slug])
    File.mkdir_p!(dir)
    path = Path.join(dir, "SKILL.md")

    steps =
      tool_seq
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {tool, idx} -> "#{idx}. Run `#{tool}`" end)

    content = """
    ---
    name: #{slug}
    description: Auto-synthesized workflow for recurring tool sequence (#{Enum.join(tool_seq, " -> ")})
    ---

    # #{slug}

    This workflow was observed repeating across multiple turns. Execute the steps in order:

    #{steps}
    """

    File.write!(path, content)

    Guardrails.propose(
      :skill,
      "Auto-synthesized skill `#{slug}` at `#{path}` for sequence: #{Enum.join(tool_seq, " -> ")}",
      cwd: cwd,
      key: "skill_" <> slug
    )

    {:ok, path}
  end

  defp extract_ngrams(list, min_len, max_len) do
    len = length(list)

    for n <- min_len..min(max_len, len),
        i <- 0..(len - n) do
      Enum.slice(list, i, n)
    end
    |> Enum.uniq()
  end

  defp save_sequences(map, cwd) do
    path = sequences_path(cwd)
    path |> Path.dirname() |> File.mkdir_p!()

    case Yoke.Json.encode(map, pretty: true) do
      {:ok, json} -> File.write!(path, json)
      _ -> :ok
    end
  end
end
