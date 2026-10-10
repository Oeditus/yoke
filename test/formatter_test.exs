defmodule Yoke.FormatterTest do
  use ExUnit.Case, async: true

  alias Yoke.CLI.Formatter

  test "renders ANSI color shortcuts" do
    assert Formatter.reset() == IO.ANSI.reset()
    assert Formatter.bold() == IO.ANSI.bright()
    assert Formatter.dim() == IO.ANSI.faint()
    assert Formatter.cyan() == IO.ANSI.cyan()
    assert Formatter.green() == IO.ANSI.green()
    assert Formatter.yellow() == IO.ANSI.yellow()
    assert Formatter.magenta() == IO.ANSI.magenta()
    assert Formatter.red() == IO.ANSI.red()
    assert Formatter.blue() == IO.ANSI.blue()
    assert Formatter.gray() == IO.ANSI.light_black()
  end

  test "provides tips list derived from help menu" do
    tips = Formatter.tips()
    assert is_list(tips)
    assert length(tips) > 10
    assert Enum.any?(tips, &String.contains?(&1, "/help"))
    assert Enum.any?(tips, &String.contains?(&1, "/compact"))

    random_tip = Formatter.random_tip()
    assert is_binary(random_tip)
    assert random_tip in tips
  end

  test "renders ASCII banner with YOKE RAGE title and actual version" do
    banner = Formatter.banner()
    assert String.contains?(banner, "YOKE RAGE")
    assert String.contains?(banner, "Yoke Agentic CLI")
    assert String.contains?(banner, "v#{Yoke.version()}")
  end

  test "renders help menu with all slash commands" do
    menu = Formatter.help_menu()
    assert String.contains?(menu, "/help")
    assert String.contains?(menu, "/guide")
    assert String.contains?(menu, "/mcp")
    assert String.contains?(menu, "/review")
    assert String.contains?(menu, "/skills")
    assert String.contains?(menu, "/compact")

    lines =
      menu
      |> String.split("\n")
      |> Enum.map(&String.trim/1)

    cmd_lines =
      Enum.filter(lines, fn line ->
        clean = Regex.replace(~r/\e\[[0-9;]*m/, line, "")

        String.starts_with?(clean, "!command") or String.starts_with?(clean, "!!") or
          String.starts_with?(clean, "/")
      end)

    cmds =
      Enum.map(cmd_lines, fn line ->
        clean = Regex.replace(~r/\e\[[0-9;]*m/, line, "")
        [first | _] = String.split(clean)
        first
      end)

    assert Enum.at(cmds, 0) == "!command"
    assert Enum.at(cmds, 1) == "!!"

    slash_cmds = Enum.drop(cmds, 2)
    assert slash_cmds == Enum.sort(slash_cmds)
  end

  test "renders getting started guide summary" do
    guide = Formatter.getting_started_guide()
    assert String.contains?(guide, "GETTING STARTED & CUSTOMIZATION GUIDE")
    assert String.contains?(guide, "BEAM/OTP")
    assert String.contains?(guide, "docs/GETTING_STARTED_GUIDE.md")
  end

  test "formats prompt string and status messages" do
    assert String.contains?(
             Formatter.format_user_prompt("main", "deepseek-chat"),
             "user@main [deepseek-chat]>"
           )

    assert String.contains?(Formatter.format_user_prompt_str("test_prompt"), "test_prompt")
    assert String.contains?(Formatter.format_agent_response("Hello"), "DeepSeek >")
    assert String.contains?(Formatter.format_error("Failed"), "●")
    assert String.contains?(Formatter.format_success("Done"), "●")
    assert String.contains?(Formatter.format_info("Notice"), "●")
  end

  test "formats markdown string with marcli rendering" do
    md = "# Title\n- Item 1\n- Item 2"
    rendered = Formatter.format_markdown(md)
    assert is_binary(rendered)
  end

  test "safely falls back to unformatted text when markdown parser raises Erlang error or case clause" do
    # Input with nested quotes/blockquotes that triggers Md.Parser case_clause
    malformed_md = "> 0.13\"}\n{:mdex, \"> 0.1\"},\nkatex, \"\n{:mdex"
    rendered = Formatter.format_markdown(malformed_md)
    assert is_binary(rendered)
    assert String.contains?(rendered, "0.13")
  end

  test "attempts copying text to system clipboard" do
    res = Formatter.copy_to_clipboard("test_clipboard_content")
    assert res == :ok or match?({:error, _}, res)
  end

  test "safe_puts handles valid text, invalid UTF-8, and improper chardata without raising" do
    invalid_utf8 = <<0xFF, 0xFE, 0xFD>>
    bad_chardata = ["valid string", 123_456_789, invalid_utf8]

    assert ExUnit.CaptureIO.capture_io(fn ->
             Formatter.safe_puts("hello world")
             Formatter.safe_puts(invalid_utf8)
             Formatter.safe_puts(bad_chardata)
           end) =~ "hello world"
  end

  describe "sanitize_utf8/1" do
    test "preserves valid UTF-8 binaries" do
      assert Formatter.sanitize_utf8("Hello, world! 🚀") == "Hello, world! 🚀"
      assert Formatter.sanitize_utf8("") == ""
    end

    test "replaces invalid byte sequences with replacement character U+FFFD" do
      invalid = "prefix" <> <<152>> <> "suffix"
      sanitized = Formatter.sanitize_utf8(invalid)
      assert String.valid?(sanitized)
      assert sanitized == "prefix\uFFFDsuffix"

      multi_invalid = <<0xFF, 0xFE, 0x98>>
      assert String.valid?(Formatter.sanitize_utf8(multi_invalid))
    end

    test "handles lists and chardata with invalid bytes" do
      chardata = ["valid", <<152>>, "end"]
      sanitized = Formatter.sanitize_utf8(chardata)
      assert String.valid?(sanitized)
      assert sanitized == "valid\uFFFDend"
    end

    test "handles nil and non-binary terms" do
      assert Formatter.sanitize_utf8(nil) == ""
      assert Formatter.sanitize_utf8(:an_atom) == "an_atom"
      assert Formatter.sanitize_utf8(12_345) == "12345"
    end
  end

  describe "display_width/1" do
    test "calculates correct width for ASCII, ANSI escapes, and wide characters" do
      assert Formatter.display_width("hello") == 5
      assert Formatter.display_width("\e[31mhello\e[0m") == 5
      assert Formatter.display_width("🚀") == 2
      assert Formatter.display_width("漢字") == 4
      assert Formatter.display_width("") == 0
    end

    test "does not crash on invalid UTF-8 byte sequences" do
      invalid = "error <<152>>" <> <<152>>
      width = Formatter.display_width(invalid)
      assert is_integer(width)
      assert width > 0

      # Raw single invalid byte
      assert Formatter.display_width(<<152>>) == 1
      assert Formatter.display_width(<<0xFF, 0xFE>>) == 2
    end

    test "safely handles nil and non-binary inputs" do
      assert Formatter.display_width(nil) == 0
      assert Formatter.display_width(123) == 0
      assert Formatter.display_width(%{}) == 0
    end
  end

  describe "format status messages with invalid UTF-8" do
    test "safely formats messages containing invalid UTF-8 bytes" do
      invalid = "crash at <<152>>: " <> <<152>>
      err = Formatter.format_error(invalid)
      assert String.valid?(err)
      assert String.contains?(err, "crash at <<152>>:")

      warn = Formatter.format_warning(invalid)
      assert String.valid?(warn)

      info = Formatter.format_info(invalid)
      assert String.valid?(info)

      succ = Formatter.format_success(invalid)
      assert String.valid?(succ)

      prompt = Formatter.format_user_prompt_str(invalid)
      assert String.valid?(prompt)
    end
  end
end
