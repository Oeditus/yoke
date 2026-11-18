defmodule Yoke.CLI.MdexNifTest do
  use ExUnit.Case, async: false

  alias Yoke.CLI.Formatter
  alias Yoke.CLI.MarkdownFallback
  alias Yoke.CLI.MdexNif

  setup do
    MdexNif.reset_cache()
    on_exit(fn -> MdexNif.reset_cache() end)
    :ok
  end

  describe "available?/0" do
    test "returns true in test environment where mdex_native priv exists on disk" do
      assert MdexNif.available?() == true
      # Cached path returns the same result
      assert MdexNif.available?() == true
    end
  end

  describe "extract_and_register/3" do
    test "extracts gzipped NIF and registers ebin on the Erlang code path" do
      tmp_root =
        Path.join(System.tmp_dir!(), "yoke_mdex_nif_test_#{:erlang.unique_integer([:positive])}")

      app_dir = Path.join(tmp_root, "mdex_native")
      ebin_dir = Path.join(app_dir, "ebin")
      nif_name = "libtest_nif.so"
      payload = "fake-nif-binary-bytes"
      gz_payload = :zlib.gzip(payload)

      on_exit(fn ->
        :code.del_path(String.to_charlist(ebin_dir))
        File.rm_rf!(tmp_root)
      end)

      assert :ok == MdexNif.extract_and_register(app_dir, nif_name, gz_payload)
      assert File.read!(Path.join([app_dir, "priv", "native", nif_name])) == payload
      assert File.dir?(ebin_dir)
      assert Application.app_dir(:mdex_native) == app_dir
    end
  end

  describe "Formatter fallback when MdexNif is unavailable" do
    test "format_markdown/1 falls back to pure-Elixir renderer without loading NIF" do
      :persistent_term.put({MdexNif, :available}, false)

      rendered = Formatter.format_markdown("# Title\n\nSome **bold** and `code` text.")
      assert rendered =~ "Title"
      assert rendered =~ "bold"
      assert rendered =~ "code"
    end

    test "format_reasoning/2 falls back to pure-Elixir renderer with CRLF" do
      :persistent_term.put({MdexNif, :available}, false)

      rendered = Formatter.format_reasoning("**Step 1**\nCheck `mix.exs`", title: "Thinking")
      assert rendered =~ "[Thinking]"
      assert rendered =~ "Step 1"
      assert rendered =~ "mix.exs"
      assert rendered =~ "\r\n"
    end
  end

  describe "MarkdownFallback.render/2" do
    test "renders headings, lists, blockquotes, code blocks, links, and inline styles" do
      md = """
      # Heading 1
      ## Heading 2

      - bullet item
      - [x] done item
      - [ ] todo item

      > quoted line

      ---

      ```elixir
      IO.puts("hi")
      ```

      See [Yoke](https://github.com/Oeditus/yoke) with **bold**, *italic*, ~~old~~, and `inline`.
      """

      rendered = MarkdownFallback.render(md)
      assert rendered =~ "Heading 1"
      assert rendered =~ "Heading 2"
      assert rendered =~ "bullet item"
      assert rendered =~ "☑ done item"
      assert rendered =~ "☐ todo item"
      assert rendered =~ "│ quoted line"
      assert rendered =~ "────"
      assert rendered =~ ~s[IO.puts("hi")]
      assert rendered =~ "Yoke"
      assert rendered =~ "(https://github.com/Oeditus/yoke)"
      assert rendered =~ "bold"
      assert rendered =~ "italic"
      assert rendered =~ "old"
      assert rendered =~ "inline"
    end

    test "respects :newline option" do
      rendered = MarkdownFallback.render("line1\nline2", newline: "\r\n")
      assert rendered == "line1\r\nline2"
    end
  end
end
