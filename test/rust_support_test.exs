defmodule Yoke.RustSupportTest do
  use ExUnit.Case, async: true

  alias Yoke.Plugin.DefaultTools

  test "Ragex and Metastatic expose Rust language support" do
    assert Ragex.Languages.supported?(:rust)
    assert {:ok, Metastatic.Adapters.Rust} = Ragex.Languages.get_adapter(:rust)
    assert Ragex.Languages.validator(:rust) == Ragex.Editor.Validators.Rust
    assert Ragex.LanguageSupport.detect_language("src/main.rs") == :rust
  end

  test "write_file validates Rust syntax when Metastatic Rust parser is available" do
    if Code.ensure_loaded?(Metastatic.Adapters.Rust) and Metastatic.Adapters.Rust.available?() do
      tmp_dir =
        Path.join(System.tmp_dir!(), "yoke_rust_write_#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp_dir)

      try do
        valid_path = Path.join(tmp_dir, "lib.rs")
        valid_code = "use crate::foo;\npub fn bar() -> usize { 42 }\n"

        assert {:ok, _} =
                 DefaultTools.write_file(%{"path" => valid_path, "content" => valid_code})

        assert File.read!(valid_path) == valid_code

        invalid_path = Path.join(tmp_dir, "broken.rs")

        assert {:error, msg} =
                 DefaultTools.write_file(%{"path" => invalid_path, "content" => "fn main( {"})

        assert msg =~ "Rust syntax error"
        refute File.exists?(invalid_path)
      after
        File.rm_rf!(tmp_dir)
      end
    end
  end
end
