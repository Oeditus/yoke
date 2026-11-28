defmodule Yoke.LanguageSupportTest do
  use ExUnit.Case, async: true

  alias Yoke.BashTracker
  alias Yoke.Plugin.DefaultTools

  test "Ragex and Metastatic expose Go, JavaScript, TypeScript, and Ruby support" do
    assert Ragex.Languages.supported?(:go)
    assert {:ok, Metastatic.Adapters.Go} = Ragex.Languages.get_adapter(:go)
    assert Ragex.LanguageSupport.detect_language("cmd/server/main.go") == :go
    assert is_boolean(Ragex.Languages.available?(:go))

    assert Ragex.Languages.supported?(:javascript)
    assert {:ok, Metastatic.Adapters.JavaScript} = Ragex.Languages.get_adapter(:javascript)
    assert Ragex.LanguageSupport.detect_language("assets/js/app.js") == :javascript
    assert is_boolean(Ragex.Languages.available?(:javascript))

    assert Ragex.Languages.supported?(:typescript)
    assert {:ok, Metastatic.Adapters.TypeScript} = Ragex.Languages.get_adapter(:typescript)
    assert Ragex.LanguageSupport.detect_language("src/index.ts") == :typescript
    assert is_boolean(Ragex.Languages.available?(:typescript))

    assert Ragex.Languages.supported?(:ruby)
    assert {:ok, Metastatic.Adapters.Ruby} = Ragex.Languages.get_adapter(:ruby)
    assert Ragex.LanguageSupport.detect_language("lib/app.rb") == :ruby
    assert is_boolean(Ragex.Languages.available?(:ruby))
  end

  test "Ragex exposes the Prisma language-scoped plugin and analysis bridge" do
    assert [%{name: "prisma_analyze"}] = Ragex.Plugins.Prisma.tools()
    assert :elixir in Ragex.Plugins.Prisma.languages()
    assert :erlang in Ragex.Plugins.Prisma.languages()
    assert Ragex.Plugins.Prisma.available?(".")
  end

  test "Ragex exposes the MetaCredo plugin and analysis bridge" do
    assert Ragex.Plugins.MetaCredo.available?()
    assert [%{name: "metacredo_analyze"}] = Ragex.Plugins.MetaCredo.tools()
    assert :go in Ragex.Plugins.MetaCredo.languages()
    assert :javascript in Ragex.Plugins.MetaCredo.languages()
    assert :typescript in Ragex.Plugins.MetaCredo.languages()

    assert "cmd/" in MetaCredo.Config.default_included_paths()
    assert "assets/js/" in MetaCredo.Config.default_included_paths()
  end

  test "BashTracker recommends mcp_ragex_metacredo_analyze for mix metacredo" do
    assert {:ok, analog} = BashTracker.suggest_analog("mix metacredo --diff")
    assert analog.analog =~ "mcp_ragex_metacredo_analyze"
  end

  test "BashTracker recommends mcp_ragex_prisma_analyze for mix prisma" do
    assert {:ok, analog} = BashTracker.suggest_analog("mix prisma --mode gradual")
    assert analog.analog =~ "mcp_ragex_prisma_analyze"
  end

  test "write_file validates Go syntax when Metastatic Go parser is available" do
    if Code.ensure_loaded?(Metastatic.Adapters.Go) and Metastatic.Adapters.Go.available?() do
      tmp_dir =
        Path.join(System.tmp_dir!(), "yoke_go_write_#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp_dir)

      try do
        valid_path = Path.join(tmp_dir, "main.go")
        valid_code = "package main\n\nfunc answer() int {\n\treturn 42\n}\n"

        assert {:ok, _} =
                 DefaultTools.write_file(%{"path" => valid_path, "content" => valid_code})

        assert File.read!(valid_path) == valid_code

        invalid_path = Path.join(tmp_dir, "broken.go")

        assert {:error, msg} =
                 DefaultTools.write_file(%{
                   "path" => invalid_path,
                   "content" => "package main\nfunc main( {\n"
                 })

        assert msg =~ "Go syntax error"
        refute File.exists?(invalid_path)
      after
        File.rm_rf!(tmp_dir)
      end
    end
  end

  test "write_file validates JavaScript and TypeScript syntax with dialect separation" do
    if System.find_executable("node") != nil and
         Code.ensure_loaded?(Metastatic.Adapters.JavaScript) and
         Code.ensure_loaded?(Metastatic.Adapters.TypeScript) do
      tmp_dir =
        Path.join(System.tmp_dir!(), "yoke_jsts_write_#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp_dir)

      try do
        js_path = Path.join(tmp_dir, "app.js")
        js_code = "export function add(a, b) { return a + b; }\n"

        assert {:ok, _} = DefaultTools.write_file(%{"path" => js_path, "content" => js_code})
        assert File.read!(js_path) == js_code

        ts_in_js_path = Path.join(tmp_dir, "typed_in_js.js")

        assert {:error, js_err} =
                 DefaultTools.write_file(%{
                   "path" => ts_in_js_path,
                   "content" => "const x: number = 1;\n"
                 })

        assert js_err =~ "JavaScript syntax error"
        refute File.exists?(ts_in_js_path)

        ts_path = Path.join(tmp_dir, "app.ts")
        ts_code = "export function add(a: number, b: number): number { return a + b; }\n"

        assert {:ok, _} = DefaultTools.write_file(%{"path" => ts_path, "content" => ts_code})
        assert File.read!(ts_path) == ts_code

        broken_ts_path = Path.join(tmp_dir, "broken.ts")

        assert {:error, ts_err} =
                 DefaultTools.write_file(%{
                   "path" => broken_ts_path,
                   "content" => "export function add(a: number {\n"
                 })

        assert ts_err =~ "TypeScript syntax error"
        refute File.exists?(broken_ts_path)
      after
        File.rm_rf!(tmp_dir)
      end
    end
  end

  test "write_file validates Ruby syntax when Metastatic Ruby parser is available" do
    if Code.ensure_loaded?(Metastatic.Adapters.Ruby) and Metastatic.Adapters.Ruby.available?() do
      tmp_dir =
        Path.join(System.tmp_dir!(), "yoke_ruby_write_#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp_dir)

      try do
        valid_path = Path.join(tmp_dir, "app.rb")
        valid_code = "def greet(name)\n  \"Hello, \#{name}\"\nend\n"

        assert {:ok, _} =
                 DefaultTools.write_file(%{"path" => valid_path, "content" => valid_code})

        assert File.read!(valid_path) == valid_code

        invalid_path = Path.join(tmp_dir, "broken.rb")

        assert {:error, rb_err} =
                 DefaultTools.write_file(%{
                   "path" => invalid_path,
                   "content" => "def broken(\n"
                 })

        assert rb_err =~ "Ruby syntax error"
        refute File.exists?(invalid_path)
      after
        File.rm_rf!(tmp_dir)
      end
    end
  end
end
