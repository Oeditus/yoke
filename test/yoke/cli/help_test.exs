defmodule Yoke.CLI.HelpTest do
  use ExUnit.Case, async: true

  alias Yoke.CLI.Formatter
  alias Yoke.CLI.Help

  test "REPL routes contextual help without touching a session or executing the command" do
    for topic <- ["workflow", "/workflow", "workflow abort nonexistent-run", "not-a-command"] do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert :continue = Yoke.CLI.Repl.handle_input("/help " <> topic, self(), "help-only")
        end)

      assert output == Help.text(topic) <> "\n"
      refute output =~ "Unknown command"
    end
  end

  test "empty topic preserves the existing command menu" do
    assert Help.text() == Formatter.help_menu()
    assert Help.text("  ") == Formatter.help_menu()
  end

  test "workflow documents every supported subcommand with syntax and examples" do
    help = Help.text("workflow")

    for syntax <- [
          "/workflow list",
          "/workflow run <name> [task description]",
          "/workflow status [run-id]",
          "/workflow resume <run-id>",
          "/workflow abort <run-id>",
          "/workflow init <name> [--from <template>]"
        ] do
      assert help =~ syntax
    end

    assert help =~ "Example: /workflow run elixir Add validation"
    assert help =~ "Example: /workflow init team-flow --from elixir"
    assert help =~ "original"
    assert help =~ "Completed or aborted runs cannot resume"
    assert help =~ "does not forcibly"
    assert help =~ "without overwriting"
    assert help =~ ".yoke/workflows/definitions/"
    assert help =~ "not a conversation/session ID"
    refute help =~ "Unknown help topic"
  end

  test "normalizes whitespace, an optional slash, and command arguments" do
    assert Help.text(" /workflow  status ") == Help.text("workflow")
    assert Help.text("workflow run anything") == Help.text("workflow")
    assert Help.text("/skills show review") == Help.text("skills")
  end

  test "reuses documentation functions rather than invoking their commands" do
    assert Help.text("review") == Formatter.review_help()
    assert Help.text("cr") == Formatter.review_help()
    assert Help.text("prboard") == Formatter.review_help()
    assert Help.text("guide") == Formatter.getting_started_guide()
    assert Help.text("docs") == Formatter.getting_started_guide()
    assert Help.text("linter") == Yoke.Linter.help_text()
    assert Help.text("lint") == Yoke.Linter.help_text()
  end

  test "aliases resolve to their canonical topic" do
    for {alternate, canonical} <- [
          {"quit", "exit"},
          {"aliases", "alias"},
          {"cb", "clipboard"},
          {"models", "model"},
          {"skill", "skills"},
          {"status", "session"},
          {"conversation", "review_conversation"},
          {"review-conversation", "review_conversation"},
          {"pr", "finish"},
          {"cpr", "commit-structured"}
        ] do
      assert Help.text(alternate) == Help.text(canonical)
    end
  end

  test "every literal slash command dispatched by the REPL has contextual help" do
    repl_path = Path.expand("../../../lib/yoke/cli/repl.ex", __DIR__)
    source = File.read!(repl_path)
    commands = Regex.scan(~r/def handle_input\("\/([a-z_-]+)/, source)

    for [_, command] <- commands do
      help = Help.text(command)
      refute help =~ "Unknown help topic", "Missing help for /#{command}"
      refute help == Formatter.help_menu(), "Only generic menu returned for /#{command}"
    end
  end

  test "help describes effects instead of performing them" do
    assert ExUnit.CaptureIO.capture_io(fn ->
             assert Help.text("workflow abort nonexistent-run") =~ "Mark a saved run aborted"
             assert Help.text("jobs kill all") =~ "/jobs kill all"
             assert Help.text("reset") =~ "Clear conversation history"
             assert Help.text("update") =~ "self-update"
           end) == ""
  end

  test "shell shortcuts have documentation without executing a shell" do
    assert Help.text("!") =~ "!<command>"
    assert Help.text("!!") =~ "Type !! again"
  end

  test "unknown topics give navigation and custom alias guidance" do
    help = Help.text("/not-a-command")
    assert help =~ "Unknown help topic 'not-a-command'"
    assert help =~ "/help for available commands"
    assert help =~ "/help workflow"
    assert help =~ "/help alias"
  end

  test "mode names and conversation resume are not confused with workflow syntax" do
    assert Help.text("spar") =~ "[socratic|adversarial]"
    assert Help.text("resume") =~ "not a workflow"
    assert Help.text("mode") =~ "not the generation provider"
    assert Help.text("permissions") =~ "/permissions <auto|yolo|ask>"
  end
end
