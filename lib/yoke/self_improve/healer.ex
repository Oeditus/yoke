defmodule Yoke.SelfImprove.Healer do
  @moduledoc """
  Self-healing prompt rules and tool-error reflexes.

  - Proposes high-salience scoped rules via `Guardrails` when `Critic` detects
    recurring tool misuse (e.g. plain-bash fallbacks or edit thrashing).
  - Caches deterministic tool-error reflexes in `.yoke/reflexes.json`.
  """

  alias Yoke.SelfImprove.Guardrails

  @reflexes_file ".yoke/reflexes.json"

  @doc "Returns `.yoke/reflexes.json` path under `cwd`."
  def reflexes_path(cwd \\ "."), do: Path.join(cwd, @reflexes_file)

  @doc "Loads cached tool-error reflexes."
  def load_reflexes(cwd \\ ".") do
    path = reflexes_path(cwd)

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

  @doc "Records a deterministic tool-error reflex (`error_pattern -> hint`)."
  def record_reflex(error_pattern, hint, cwd \\ ".")
      when is_binary(error_pattern) and is_binary(hint) do
    key = String.trim(error_pattern)
    reflexes = load_reflexes(cwd)
    entry = %{"hint" => String.trim(hint), "hits" => (reflexes[key]["hits"] || 0) + 1}
    updated = Map.put(reflexes, key, entry)

    path = reflexes_path(cwd)
    path |> Path.dirname() |> File.mkdir_p!()

    case Yoke.Json.encode(updated, pretty: true) do
      {:ok, json} ->
        File.write!(path, json)
        {:ok, entry}

      err ->
        err
    end
  end

  @doc "Looks up a matching reflex hint for `error_text`."
  def lookup_reflex(error_text, cwd \\ ".") when is_binary(error_text) do
    down = String.downcase(error_text)

    load_reflexes(cwd)
    |> Enum.find_value(fn {pattern, %{"hint" => hint}} ->
      if String.contains?(down, String.downcase(pattern)), do: hint
    end)
  end

  @doc """
  Inspects `Critic.evaluate/2` findings and proposes scoped rules into `Guardrails`
  when recurring anti-patterns are observed.
  """
  def heal_from_critic(%{findings: findings}, cwd \\ ".") when is_list(findings) do
    Enum.flat_map(findings, fn finding ->
      cond do
        String.contains?(finding, "plain bash") ->
          {:ok, item} =
            Guardrails.propose(
              :rule,
              "all: Prefer dedicated tools (grep_search, read_file, mcp_ragex_*) over plain bash.",
              cwd: cwd,
              key: "heal_no_plain_bash"
            )

          [item]

        String.contains?(finding, "without reading its test file") ->
          {:ok, item} =
            Guardrails.propose(
              :rule,
              "test: Always read the corresponding test file before making repeated edits to an implementation file.",
              cwd: cwd,
              key: "heal_read_tests_first"
            )

          [item]

        true ->
          []
      end
    end)
  end
end
