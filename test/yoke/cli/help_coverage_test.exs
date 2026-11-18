defmodule Yoke.CLI.HelpCoverageTest do
  @moduledoc """
  A static audit of the `/help` menu against the commands the REPL actually
  implements.

  The menu is hand-written prose, so it drifts: `/practices` was reachable and
  documented in the getting-started guide, but missing from the menu, so a user
  who ran `/help` had no way to discover it. This test reads both files as text
  and asserts the two agree, in the same style as
  `test/interaction_call_sites_test.exs`.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../../..", __DIR__)
  @repl_source File.read!(Path.join(@root, "lib/yoke/cli/repl.ex"))
  @formatter_source File.read!(Path.join(@root, "lib/yoke/cli/formatter.ex"))

  # Commands implemented as a literal `handle_input("/name", ...)` or
  # `handle_input("/name " <> ..., ...)` clause.
  defp implemented_commands do
    ~r/handle_input\("(\/[a-z][a-z0-9_\-]*)/
    |> Regex.scan(@repl_source)
    |> Enum.map(fn [_, command] -> command end)
    |> Enum.uniq()
  end

  defp menu_commands do
    ~r/\{cyan\(\)}(\/[a-z][a-z0-9_\-]*)/
    |> Regex.scan(@formatter_source)
    |> Enum.map(fn [_, command] -> command end)
    |> Enum.uniq()
  end

  # Documented aliases: a command that exists only to forward to another one
  # does not need its own menu line, as long as the target is documented.
  @aliases %{
    "/quit" => "/exit",
    "/getting-started" => "/guide",
    "/linter" => "/lint",
    "/aliases" => "/alias",
    "/status" => "/session",
    "/conversation" => "/session",
    "/review-conversation" => "/review_conversation",
    "/tokens" => "/cost",
    "/audit-thoughts" => "/audit",
    "/what-next" => "/audit",
    "/backlog" => "/audit",
    "/thought" => "/audit",
    "/paste" => "/edit",
    "/promote" => "/lessons",
    "/process-scrap" => "/scrap",
    "/prune-lessons" => "/lessons",
    "/prune-completed" => "/review",
    "/config" => "/explorer"
  }

  defp documented?(command, menu) do
    MapSet.member?(menu, command) or
      (Map.has_key?(@aliases, command) and MapSet.member?(menu, Map.fetch!(@aliases, command)))
  end

  test "every implemented slash command appears in the /help menu" do
    menu = MapSet.new(menu_commands())

    missing =
      implemented_commands()
      |> Enum.reject(&documented?(&1, menu))
      |> Enum.sort()

    assert missing == [],
           "these slash commands are implemented but missing from Formatter.help_menu/0: " <>
             Enum.join(missing, ", ")
  end

  test "the menu does not advertise a command the REPL cannot handle" do
    implemented = MapSet.new(implemented_commands())

    ghosts =
      menu_commands()
      |> Enum.reject(&MapSet.member?(implemented, &1))
      |> Enum.sort()

    assert ghosts == [],
           "these commands are in the /help menu but have no handle_input/3 clause: " <>
             Enum.join(ghosts, ", ")
  end

  test "the audit itself finds a non-trivial number of commands" do
    # Guards against the regexes silently matching nothing, which would make
    # both assertions above vacuously true.
    assert length(implemented_commands()) > 20
    assert length(menu_commands()) > 20
  end
end
