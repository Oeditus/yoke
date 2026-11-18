defmodule Yoke.PlanGate do
  @moduledoc """
  Pure decision logic for Yoke's hardcoded "plan -> approve -> execute" gate.

  When a batch of tool calls looks non-trivial (>= 2 file-modifying calls), the
  agent is expected to pause and present a plan for approval before executing.
  This module classifies tool calls, counts modifiers, decides whether the plan
  gate is needed, renders a readable plan, and maps the user's approval-modal
  selection to a decision atom.
  """

  @file_modifiers ~w(
    write_file replace_file edit_file git_commit
    mcp_ragex_edit_file mcp_ragex_edit_files mcp_ragex_refactor_code mcp_ragex_advanced_refactor mcp_ragex_rollback_edit
    ragex_edit_file ragex_edit_files ragex_refactor_code ragex_advanced_refactor ragex_rollback_edit
  )

  # Commands whose *first word* is enough to classify the command as
  # write-capable, regardless of arguments. A token check rather than a
  # substring one, so `scp`/`rsync` no longer match the `cp ` marker and
  # `git checkout` is caught even though it is not in the substring list.
  @write_first_words ~w(
    rm rmdir mv cp ln tee dd mkfs mkfs.ext4 mkfs.xfs truncate shred chmod chown
    touch mkdir install patch
  )

  # `git <subcommand>` pairs that write to the working tree or the repository.
  @write_git_subcommands ~w(
    commit push add reset rm mv checkout restore clean stash apply am rebase merge
    cherry-pick revert tag branch worktree gc prune
  )

  # Package-manager / build commands that publish or install into the tree.
  @write_command_fragments [
    "cargo publish",
    "mix hex.publish",
    "npm publish",
    "yarn publish",
    "pnpm publish",
    "curl -o",
    "curl --output",
    "wget ",
    "drop database"
  ]

  # Interpreters that can write without any shell redirection.
  @interpreter_first_words ~w(python python2 python3 perl ruby node php)
  @doc """
  Returns true when a tool call is considered file-modifying (write-ish/destructive).

  `tool_name` may be a binary or atom. `args` is a string-keyed map (may be empty).
  A call counts if its name is `write_file`, `replace_file`, `edit_file`, `git_commit`,
  or any Ragex file editing / refactoring tool (`mcp_ragex_edit_file`, `mcp_ragex_refactor_code`, etc.);
  or if its name is `bash` and its `"command"` looks write-ish.
  """
  def modifier_tool?(tool_name, args \\ %{}) do
    name = normalize_name(tool_name)

    cond do
      name in @file_modifiers -> true
      name == "bash" -> write_ish_bash?(args)
      true -> false
    end
  end

  @doc """
  Returns true when a bash `"command"` string looks write-ish/destructive.

  Pure read-only commands (`ls`, `cat`, `grep`, `git status`, `mix test`, ...)
  return false. Redirection tokens are only counted when they appear as real
  tokens, guarding against false positives like `->` or `=>`.

  This is a best-effort heuristic for the *interactive* plan gate, where a
  false negative costs an extra prompt. It is deliberately NOT used to
  authorise a read-only (`:ci`) run: `Yoke.Hands.Executor.write_tool?/2`
  refuses the shell outright there, because no substring classifier can decide
  whether an arbitrary command writes (`python3 -c "open('f','w')"`,
  `perl -pi -e`, `git checkout -- .`).
  """
  def write_ish_bash?(args) when is_map(args) do
    case fetch_command(args) do
      "" -> false
      command -> write_ish_command?(command)
    end
  end

  def write_ish_bash?(_), do: false

  @doc """
  Counts how many tool calls in a batch are modifiers.

  Accepts a list of maps with `"name"`/`:name` and `"arguments"`/`:arguments`
  keys (string or atom). Returns a non-negative integer.
  """
  def count_modifiers(tool_calls) when is_list(tool_calls) do
    tool_calls
    |> Enum.map(&normalize_call/1)
    |> Enum.count(fn {name, args} -> modifier_tool?(name, args) end)
  end

  def count_modifiers(_), do: 0

  @doc """
  Returns true when a batch of tool calls should trigger the plan gate.

  True when `count_modifiers(tool_calls) >= threshold`. Empty or nil input
  returns false.
  """
  def needs_plan?(tool_calls, threshold \\ 2) do
    is_list(tool_calls) and tool_calls != [] and count_modifiers(tool_calls) >= threshold
  end

  @doc """
  Renders a `plan` map into a short, readable Markdown-ish binary.

  Accepts optional string keys `"summary"`, `"steps"` (a list of strings or
  maps), and `"files"` (a list). Falls back to a friendly notice when there is
  nothing usable to render.
  """
  def render_plan(plan) when is_map(plan) do
    summary = Map.get(plan, "summary", Map.get(plan, :summary, ""))

    steps =
      Map.get(plan, "steps", Map.get(plan, :steps, []))
      |> normalize_steps()

    files =
      Map.get(plan, "files", Map.get(plan, :files, []))
      |> normalize_list()

    if summary == "" and steps == [] and files == [] do
      "(no plan structure provided)"
    else
      [
        if(summary == "", do: nil, else: "## Summary\n\n#{summary}"),
        if(steps == [],
          do: nil,
          else: "## Steps\n\n" <> Enum.map_join(steps, "\n", &("- " <> &1))
        ),
        if(files == [],
          do: nil,
          else: "## Files\n\n" <> Enum.map_join(files, "\n", &("- `" <> &1 <> "`"))
        )
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n\n")
    end
  end

  def render_plan(_), do: "(no plan structure provided)"

  @doc """
  Maps a user's approval-modal selection to a decision atom.

  Options are matched case-insensitively by substring/prefix: `Approve & execute`
  -> `:approve`, `Request changes` -> `:request_changes`, `Deny` -> `:deny`.
  Anything unrecognized returns `:unknown`.
  """
  def decision_from_selection(selected) when is_binary(selected) do
    down = String.downcase(selected)

    cond do
      String.contains?(down, "approve") -> :approve
      String.contains?(down, "request") or String.contains?(down, "changes") -> :request_changes
      String.contains?(down, "deny") -> :deny
      true -> :unknown
    end
  end

  def decision_from_selection(_), do: :unknown

  # --- Private helpers ---

  defp normalize_name(name) when is_atom(name), do: Atom.to_string(name)
  defp normalize_name(name) when is_binary(name), do: name
  defp normalize_name(_), do: ""

  defp fetch_command(args) do
    args
    |> Map.get("command", Map.get(args, :command, ""))
    |> to_string()
  end

  defp write_ish_command?(command) do
    down = String.downcase(command)

    # Split on shell separators first so `cd lib && rm -rf build` is classified
    # by `rm`, not by `cd`.
    segments = String.split(down, ~r/\s*(?:&&|\|\||;|\n)\s*/)

    cond do
      segments == [] -> false
      Enum.any?(segments, &segment_writes?/1) -> true
      true -> false
    end
  end

  defp segment_writes?(segment) do
    # A leading redirection (`> out.txt`) has no first word.
    redirection?(segment) or
      segment_tokens_write?(segment |> String.split(~r/\s+/, trim: true))
  end

  defp segment_tokens_write?([]) do
    false
  end

  defp segment_tokens_write?(tokens) do
    first_word_writes?(tokens) or
      sed_in_place?(tokens) or
      git_subcommand_writes?(tokens) or
      interpreter_writes?(tokens) or
      Enum.any?(@write_command_fragments, &String.contains?(Enum.join(tokens, " "), &1))
  end

  defp first_word_writes?([first | _]) do
    first in @write_first_words or
      String.starts_with?(first, "mkfs") or
      String.starts_with?(first, "./")
  end

  # `sed -i` edits in place; plain `sed` is a filter and stays read-only.
  defp sed_in_place?(["sed" | rest]) do
    Enum.any?(rest, fn token ->
      token == "-i" or String.starts_with?(token, "-i") or
        String.starts_with?(token, "--in-place")
    end)
  end

  defp sed_in_place?(_), do: false

  defp git_subcommand_writes?(["git", sub | _]), do: sub in @write_git_subcommands
  defp git_subcommand_writes?(_), do: false

  # An interpreter with an inline program can write without any shell
  # redirection (`python3 -c "open('f','w')"`). Treating every interpreter
  # invocation as write-ish costs one extra prompt in the interactive gate,
  # which is the cheap direction to be wrong in.
  defp interpreter_writes?([first | _]) do
    first in @interpreter_first_words or
      Enum.any?(@interpreter_first_words, &String.ends_with?(first, "/" <> &1))
  end

  # A real redirection operator, with or without surrounding whitespace
  # (`echo hi>out.txt`), but never the `>` inside `->` or `=>` and never the
  # `>&` fd-duplication operator. A `>` is a redirect unless the character
  # immediately before it is `-` or `=`.
  defp redirection?(segment) do
    Regex.match?(~r/(?:\A|[^\-=])>/, segment)
  end

  defp normalize_call(call) when is_map(call) do
    name =
      call
      |> Map.get("name", Map.get(call, :name, ""))
      |> normalize_name()

    args =
      case Map.get(call, "arguments", Map.get(call, :arguments, %{})) do
        %{} = map when map_size(map) > 0 ->
          map

        _ ->
          # Fall back to a top-level bash `command`/`command` key.
          case Map.get(call, "command", Map.get(call, :command)) do
            nil -> %{}
            cmd -> %{"command" => to_string(cmd)}
          end
      end

    {name, args}
  end

  defp normalize_call(_), do: {"", %{}}

  defp normalize_steps(steps) when is_list(steps) do
    Enum.map(steps, fn
      step when is_binary(step) -> step
      step when is_map(step) -> Map.get(step, "description", Map.get(step, :description, ""))
      _ -> ""
    end)
    |> Enum.reject(&(&1 == ""))
  end

  defp normalize_steps(_), do: []

  defp normalize_list(list) when is_list(list), do: Enum.map(list, &to_string/1)
  defp normalize_list(_), do: []
end
