defmodule Yoke.ShellHistory do
  @moduledoc """
  Reads the last command from the *user's terminal* history, so `yoke fix` can
  pick up whatever the user just ran (typically a failing build/test command)
  and hand it to the agent for analysis.

  ## Why not just `~/.yoke/history`?

  `Yoke.CLI.LineEditor` keeps Yoke's own prompt history, but the command that
  failed almost always ran in the user's shell *before* Yoke was launched --
  `mix test`, `cargo build`, `make`, a `docker compose up` that exploded. That
  lives in the shell's history file, which is what this module reads.

  ## Sources, in priority order

  1. `$YOKE_LAST_COMMAND` -- explicit override, also how the launcher can pass
     the command it was invoked from. Always wins when set and non-empty.
  2. `$HISTFILE` -- zsh/bash honour this, so it is authoritative when set.
  3. zsh: `$ZDOTDIR/.zsh_history`, then `~/.zsh_history`.
  4. bash: `$HISTFILE`-less fallback `~/.bash_history`.
  5. fish: `$XDG_DATA_HOME/fish/fish_history` (or `~/.local/share/...`).

  Both zsh's extended history format (`: <epoch>:<duration>;<command>`) and
  bash's plain `HISTTIMEFORMAT`-style `#<epoch>` marker lines are understood,
  as are multi-line commands (a command continued with a trailing `\\`), which
  are joined back into a single entry.

  The most recent entry is returned *as typed*. Entries that are themselves
  Yoke invocations (`yoke`, `./yoke`, `yoke_escript`, `yoke fix`, ...) are
  skipped -- otherwise running `yoke fix` twice in a row would analyse the
  previous `yoke fix` instead of the command that actually failed.
  """

  @yoke_invocations ~w(yoke yoke_escript ./yoke ./yoke_escript)
  @fix_self_reference ~r/^\s*(\.\/)?yoke(_escript)?(\s|$)/

  @doc """
  Returns the last non-Yoke command from the user's terminal history.

  ## Options

    * `:history_file` -- read this file instead of auto-detecting. Useful for
      tests and for `yoke fix --from-history <path>`.
    * `:skip` -- number of most-recent (non-Yoke) entries to skip before
      returning one. `skip: 0` (default) returns the most recent command,
      `skip: 1` the one before it, and so on. Enables `yoke fix --previous`.

  Returns `{:ok, command}` or `{:error, reason}`.
  """
  @spec last_command(keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def last_command(opts \\ []) do
    skip = Keyword.get(opts, :skip, 0)

    with {:ok, entries} <- read_entries(opts),
         candidates = Enum.reject(entries, &yoke_invocation?/1),
         {:ok, command} <- Enum.fetch(candidates, skip) do
      {:ok, command}
    else
      {:error, _} = error ->
        error

      :error ->
        {:error,
         "No usable command found in terminal history (skipped #{skip + 1} most recent entr#{if skip == 0, do: "y", else: "ies"})."}
    end
  end

  @doc """
  Returns every command found in the history, most recent first.
  """
  @spec commands(keyword()) :: {:ok, [String.t()]} | {:error, String.t()}
  def commands(opts \\ []) do
    with {:ok, entries} <- read_entries(opts) do
      {:ok, Enum.reject(entries, &yoke_invocation?/1)}
    end
  end

  @doc """
  Returns the candidate history file paths, in the order they are tried.
  Exposed for `yoke fix --help` and for diagnostics.
  """
  @spec candidate_files() :: [String.t()]
  def candidate_files do
    home = System.user_home() || System.get_env("HOME") || "."
    zdotdir = System.get_env("ZDOTDIR")
    xdg_data = System.get_env("XDG_DATA_HOME") || Path.join(home, ".local/share")

    [
      System.get_env("HISTFILE"),
      zdotdir && Path.join(zdotdir, ".zsh_history"),
      Path.join(home, ".zsh_history"),
      Path.join(home, ".bash_history"),
      Path.join(xdg_data, "fish/fish_history")
    ]
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
  end

  @doc """
  Returns true when `command` is itself an invocation of Yoke (so it must not
  be offered as "the command that failed").
  """
  @spec yoke_invocation?(String.t()) :: boolean()
  def yoke_invocation?(command) when is_binary(command) do
    trimmed = String.trim(command)

    cond do
      trimmed == "" -> true
      Regex.match?(@fix_self_reference, trimmed) -> true
      true -> Enum.any?(@yoke_invocations, &(&1 == trimmed))
    end
  end

  def yoke_invocation?(_), do: true

  # ---------------------------------------------------------------------
  # Internals
  # ---------------------------------------------------------------------

  defp read_entries(opts) do
    cond do
      explicit = Keyword.get(opts, :history_file) ->
        read_file(explicit)

      env_command = System.get_env("YOKE_LAST_COMMAND") ->
        if String.trim(env_command) == "" do
          read_detected()
        else
          {:ok, [String.trim(env_command)]}
        end

      true ->
        read_detected()
    end
  end

  defp read_detected do
    case Enum.find(candidate_files(), &File.regular?/1) do
      nil ->
        {:error,
         "Could not locate a shell history file (tried: #{Enum.join(candidate_files(), ", ")}). " <>
           "Pass the command explicitly with `yoke fix \"<command>\"` or set $YOKE_LAST_COMMAND."}

      path ->
        read_file(path)
    end
  end

  defp read_file(path) do
    case File.read(path) do
      {:ok, content} ->
        # `parse_lines/2` accumulates by prepending, so its result is already
        # most-recent-first -- exactly what `last_command/1` and `commands/1`
        # expect. Do not reverse it here.
        entries =
          content
          |> String.split("\n")
          |> parse_lines(fish_history?(path))

        {:ok, entries}

      {:error, reason} ->
        {:error, "Could not read shell history at #{path}: #{:file.format_error(reason)}"}
    end
  end

  defp fish_history?(path), do: String.ends_with?(path, "fish_history")

  # Parses a list of raw history lines into ordered commands (oldest first).
  #
  # Line shapes handled:
  #   zsh extended:  ": 1700000000:0;mix test"
  #   bash timestamp: "#1700000000"  (marker line, ignored)
  #   fish:          "- cmd: mix test" / "  when: 1700000000"
  #   plain:         "mix test"
  # Continuation: a line ending in an odd number of backslashes continues the
  # previous command; the continuation line is appended with a newline.
  defp parse_lines(lines, fish?) do
    lines
    |> Enum.reject(&(String.trim(&1) == ""))
    |> Enum.reduce([], fn raw, acc ->
      cond do
        fish? ->
          fish_entry(raw, acc)

        match = Regex.run(~r/^: \d+:\d+;(.*)$/s, raw) ->
          [_, command] = match
          push_command(acc, command)

        Regex.match?(~r/^#\d+$/, raw) ->
          acc

        true ->
          push_command(acc, raw)
      end
    end)
  end

  defp fish_entry(line, acc) do
    case Regex.run(~r/^- cmd: (.*)$/s, line) do
      [_, command] -> push_command(acc, command)
      _ -> acc
    end
  end

  defp push_command(acc, command) do
    command = String.trim_trailing(command)

    case acc do
      [previous | rest] ->
        if continues?(previous) do
          # Continuation lines are appended to the command they continue, so
          # the joined entry stays in the same (older) position in the list.
          # The line-continuation backslash itself is dropped, along with the
          # single space that preceded it, so `mix test \` + `  --trace`
          # joins as `mix test\n  --trace`.
          [strip_continuation(previous) <> "\n" <> command | rest]
        else
          [command | acc]
        end

      [] ->
        [command]
    end
  end

  # A trailing backslash (not itself escaped) marks a continued command.
  defp continues?(line) do
    trailing = line |> String.reverse() |> String.graphemes() |> Enum.take_while(&(&1 == "\\"))
    rem(length(trailing), 2) == 1
  end

  # Removes the line-continuation backslash and the whitespace that preceded
  # it, so a joined command reads naturally.
  defp strip_continuation(line) do
    line
    |> String.trim_trailing("\\")
    |> String.trim_trailing()
  end
end
