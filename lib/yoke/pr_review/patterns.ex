defmodule Yoke.PRReview.Patterns do
  @moduledoc """
  Living review patterns memory system.
  Maintains `.yoke/review_patterns.md` (or `~/.yoke/review_patterns.md`) to record
  valid review issues previously encountered in the codebase. High-frequency patterns
  (`Seen: 3+`) become mandatory automated checks in future code reviews.
  """

  @type pattern :: %{
          name: String.t(),
          category: String.t(),
          what: String.t(),
          how: String.t(),
          seen: integer(),
          notes: String.t()
        }

  @doc """
  Returns the path to the review patterns file for the given workspace directory.
  Prefers `.yoke/review_patterns.md` in the workspace, falls back to `~/.yoke/review_patterns.md`.
  """
  def patterns_path(cwd \\ ".") do
    local_path = Path.join([cwd, ".yoke", "review_patterns.md"])
    global_path = Path.expand("~/.yoke/review_patterns.md")

    cond do
      File.exists?(local_path) -> local_path
      File.exists?(global_path) -> global_path
      true -> local_path
    end
  end

  @doc """
  Ensures the patterns file exists. If neither local nor global exists,
  creates `.yoke/review_patterns.md` using the default template.
  """
  def ensure_patterns_file(cwd \\ ".") do
    path = patterns_path(cwd)

    if not File.exists?(path) do
      dir = Path.dirname(path)
      File.mkdir_p!(dir)
      File.write!(path, template_content())
    end

    path
  end

  @doc """
  Loads and parses all review patterns from the patterns file.
  """
  def load_patterns(cwd \\ ".") do
    path = patterns_path(cwd)

    if File.exists?(path) do
      parse_markdown(File.read!(path))
    else
      []
    end
  end

  @doc """
  Generates prompt text injecting mandatory checklist items (`Seen: 3+`)
  and optional codebase patterns into the LLM code review prompt.
  """
  def format_patterns_for_prompt(cwd \\ ".") do
    patterns = load_patterns(cwd)

    if patterns == [] do
      ""
    else
      mandatory = Enum.filter(patterns, &(&1.seen >= 3))
      other = Enum.filter(patterns, &(&1.seen < 3))

      mandatory_section =
        if mandatory == [] do
          ""
        else
          items =
            Enum.map_join(mandatory, "\n", fn p ->
              "- **[MANDATORY CHECK] #{p.name}** (Seen #{p.seen}x): #{p.what} | Verify: `#{p.how}`"
            end)

          """
          #### Mandatory Historical Tripwires (Seen: 3+)
          These issues have repeatedly occurred in this codebase. You MUST explicitly evaluate the diff against each of these:
          #{items}
          """
        end

      candidate_section =
        if other == [] do
          ""
        else
          items =
            Enum.map_join(other, "\n", fn p ->
              "- **#{p.name}** (#{p.category}, Seen #{p.seen}x): #{p.what} | Check: `#{p.how}`"
            end)

          """
          #### Known Codebase Patterns
          Check if any of these historical patterns apply:
          #{items}
          """
        end

      """

      ### Historical Codebase Review Patterns (.yoke/review_patterns.md)
      #{mandatory_section}
      #{candidate_section}
      """
    end
  end

  @doc """
  Records or updates a pattern in the patterns file based on an accepted review finding.
  If a pattern with matching or similar title exists, increments `Seen` and appends note.
  Otherwise, appends a new pattern under the closest category.
  """
  def record_finding(finding, pr_ref \\ "", cwd \\ ".") do
    ensure_patterns_file(cwd)
    path = patterns_path(cwd)
    content = File.read!(path)

    title = Map.get(finding, :title, "Unspecified Issue") |> to_string() |> String.trim()
    desc = Map.get(finding, :description, "") |> to_string() |> String.trim()
    file = Map.get(finding, :file)
    loc_note = if file, do: "#{file}#{if Map.get(finding, :line), do: ":#{finding.line}"}", else: ""
    pr_note = if pr_ref != "", do: "#{pr_ref} (#{loc_note})", else: loc_note

    existing_patterns = parse_markdown(content)

    match =
      Enum.find(existing_patterns, fn p ->
        String.downcase(p.name) == String.downcase(title) or
          String.contains?(String.downcase(title), String.downcase(p.name)) or
          String.contains?(String.downcase(p.name), String.downcase(title))
      end)

    updated_content =
      if match do
        increment_existing_pattern(content, match.name, pr_note)
      else
        category = guess_category(finding)
        append_new_pattern(content, category, title, desc, loc_note, pr_note)
      end

    File.write!(path, updated_content)
    :ok
  end

  @doc """
  Parses markdown content into structured pattern maps.
  """
  def parse_markdown(md_text) when is_binary(md_text) do
    lines = String.split(md_text, "\n")

    {patterns, _cur_cat} =
      Enum.reduce(lines, {[], "General"}, fn line, {acc, cur_cat} ->
        trimmed = String.trim(line)

        cond do
          String.starts_with?(trimmed, "## ") ->
            cat = trimmed |> String.replace_prefix("## ", "") |> String.trim()
            {acc, cat}

          String.starts_with?(trimmed, "### ") ->
            name = trimmed |> String.replace_prefix("### ", "") |> String.trim()

            pattern = %{
              name: name,
              category: cur_cat,
              what: "",
              how: "",
              seen: 1,
              notes: ""
            }

            {[pattern | acc], cur_cat}

          String.starts_with?(trimmed, "- **What**:") and acc != [] ->
            [latest | rest] = acc
            what = String.replace(trimmed, ~r/^-\s*\*\*What\*\*:\s*/, "") |> String.trim()
            {[%{latest | what: what} | rest], cur_cat}

          String.starts_with?(trimmed, "- **How to check**:") and acc != [] ->
            [latest | rest] = acc
            how = String.replace(trimmed, ~r/^-\s*\*\*How to check\*\*:\s*/, "") |> String.trim()
            {[%{latest | how: how} | rest], cur_cat}

          String.starts_with?(trimmed, "- **Seen**:") and acc != [] ->
            [latest | rest] = acc
            seen_str = String.replace(trimmed, ~r/^-\s*\*\*Seen\*\*:\s*/, "") |> String.trim()
            {seen_cnt, notes} = parse_seen_field(seen_str)
            {[%{latest | seen: seen_cnt, notes: notes} | rest], cur_cat}

          true ->
            {acc, cur_cat}
        end
      end)

    Enum.reverse(patterns)
  end

  defp parse_seen_field(seen_str) do
    case Regex.run(~r/^(\d+)(?:\+)?(?:\s*[—\-]\s*(.*))?/, seen_str) do
      [_, cnt, notes] ->
        {String.to_integer(cnt), String.trim(notes || "")}

      [_, cnt] ->
        {String.to_integer(cnt), ""}

      _ ->
        {1, seen_str}
    end
  end

  defp increment_existing_pattern(content, name, pr_note) do
    # Find pattern header and replace Seen line
    header_pattern = ~r/(###\s+#{Regex.escape(name)}[\s\S]*?-\s*\*\*Seen\*\*:\s*)(\d+)(\+)?([^\n]*)/

    Regex.replace(header_pattern, content, fn _full, pre, cnt_str, plus, rest ->
      next_count = String.to_integer(cnt_str) + 1
      notes = String.trim(rest)

      new_notes =
        cond do
          pr_note == "" -> notes
          notes == "" -> "— #{pr_note}"
          true -> "#{notes}, #{pr_note}"
        end

      "#{pre}#{next_count}#{plus || ""} #{new_notes}"
    end)
  end

  defp append_new_pattern(content, category, title, desc, loc_note, pr_note) do
    cat_header = "## #{category}"

    check_how =
      if loc_note != "",
        do: "Grep for relevant changes in `#{loc_note}` or callers.",
        else: "Examine diff for matching pattern."

    new_block = """

    ### #{title}
    - **What**: #{desc}
    - **How to check**: #{check_how}
    - **Seen**: 1 — #{if pr_note != "", do: pr_note, else: "accepted review finding"}
    """

    if String.contains?(content, cat_header) do
      String.replace(content, cat_header, cat_header <> new_block)
    else
      content <> "\n\n" <> cat_header <> new_block
    end
  end

  defp guess_category(finding) do
    title = (Map.get(finding, :title, "") <> " " <> Map.get(finding, :description, "")) |> String.downcase()

    cond do
      String.contains?(title, ["auth", "security", "token", "leak", "secret", "sql", "inject", "sanitize"]) ->
        "Security / Safety"

      String.contains?(title, ["schema", "database", "migration", "index", "column", "table", "ecto", "foreign key"]) ->
        "Data / Schema"

      String.contains?(title, ["test", "coverage", "assert", "mock", "exunit", "flaky"]) ->
        "Testing"

      String.contains?(title, ["naming", "style", "format", "convention", "doc", "comment"]) ->
        "Convention / Scope"

      true ->
        "Correctness"
    end
  end

  @doc """
  Default template content for `review_patterns.md`.
  """
  def template_content do
    """
    # Review Patterns: Living Document

    Valid review comments that real PRs in your codebase have received.
    Yoke checks every diff against these before drafting observations.
    Entries with `Seen: 3+` are mandatory checks on every relevant diff.

    ---

    ## Correctness

    ### Shared Helper Contract Drift
    - **What**: Modifying a shared function, schema default, or helper without updating callers.
    - **How to check**: Grep codebase for all usages of the modified function or schema.
    - **Seen**: 1 — initial template

    ## Security / Safety

    ### Unchecked Authorization Boundary
    - **What**: Endpoint or mutation assumes authenticated user without checking ownership or role.
    - **How to check**: Verify current user ID matches resource tenant/owner ID in handler.
    - **Seen**: 1 — initial template

    ## Data / Schema

    ### Missing Index on Foreign Key
    - **What**: Adding a new reference/foreign key column in migration without an index.
    - **How to check**: Grep migration diff for `add :..._id, references(` and ensure `create index` accompanies it.
    - **Seen**: 1 — initial template

    ## Testing

    ### Untested Error or Fallback Branch
    - **What**: Adding a new `{:error, _}` or `else` branch without a corresponding test case driving it.
    - **How to check**: Check ExUnit tests for coverage of edge/failure paths.
    - **Seen**: 1 — initial template

    ## Convention / Scope

    ### Flag-Off Path Divergence
    - **What**: Feature flag default or disabled state does not preserve legacy behavior.
    - **How to check**: Verify flag-off execution path produces identical output to base branch.
    - **Seen**: 1 — initial template
    """
  end
end
