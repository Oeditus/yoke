defmodule Yoke.ProjectGuidanceTest do
  use ExUnit.Case, async: false

  alias Yoke.Config
  alias Yoke.Practices

  @project_root Path.expand("..", __DIR__)
  @practice_path Path.join(@project_root, ".yoke/practices/elixir.lmml")

  @tag :tmp_dir
  test "shared Elixir practices are valid LMML and load through the project API", %{
    tmp_dir: tmp_dir
  } do
    assert {:ok, bundle} = Lmml.open(@practice_path)
    assert :ok = Lmml.validate(bundle)
    assert {:ok, %Lmml.Manifest{data: manifest}} = Lmml.manifest(bundle)
    assert manifest["language"] == "elixir"
    assert [_ | _] = manifest["sources"]

    for source <- manifest["sources"] do
      assert Path.type(source) == :relative
      assert File.regular?(Path.join(@project_root, source))
    end

    opts = [global_dir: Path.join(tmp_dir, "absent-global-practices")]
    assert Practices.has_practices?("elixir", @project_root, opts)
    loaded = Practices.load_practices("elixir", @project_root, opts)

    assert loaded.language == "elixir"
    assert loaded.manifest == manifest
    assert loaded.sources == manifest["sources"]
    assert [_ | _] = loaded.items
    assert Enum.all?(loaded.items, &String.contains?(loaded.narrative, &1))

    preamble = Practices.build_preamble(@project_root, [languages: ["elixir"]] ++ opts)
    assert preamble =~ "=== Language Good Practices ==="
    assert preamble =~ "### Good Practices for Elixir"

    for item <- loaded.items do
      assert preamble =~ "- " <> item
    end
  end

  test "project discovery exposes both tracked rules and Elixir practices" do
    prior = Application.fetch_env(:yoke, :project_languages)
    Application.put_env(:yoke, :project_languages, ["elixir"])

    on_exit(fn ->
      case prior do
        {:ok, value} -> Application.put_env(:yoke, :project_languages, value)
        :error -> Application.delete_env(:yoke, :project_languages)
      end
    end)

    rules = File.read!(Path.join(@project_root, ".yokerules"))
    guidance = Config.discover_project_rules(@project_root)

    assert guidance =~ "=== Project Rule (.yokerules) ==="
    assert guidance =~ rules
    assert guidance =~ "### Good Practices for Elixir"
    assert guidance =~ "Keep OTP actors responsive:"
    assert guidance =~ "Regression tests must not make provider/network calls"
    assert guidance =~ "built-in `JSON`/OTP `:json`"
  end

  test "gitignore shares only the existing policy and the Elixir practice under .yoke" do
    shared = [".yokerules", ".yoke/policy.json", ".yoke/practices/elixir.lmml"]

    ignored = [
      ".yoke/config.json",
      ".yoke/sessions/example.lmml",
      ".yoke/checkpoints/example.json",
      ".yoke/logs/example.log",
      ".yoke/review_patterns.md",
      ".yoke/practices/python.lmml",
      ".yoke/practices/config.json",
      ".yoke/practices/local/elixir.lmml"
    ]

    args = [
      "-c",
      "core.excludesFile=/dev/null",
      "--no-pager",
      "check-ignore",
      "--no-index",
      "--"
    ]

    assert {"", 1} = System.cmd("git", args ++ shared, cd: @project_root)
    assert {output, 0} = System.cmd("git", args ++ ignored, cd: @project_root)
    assert String.split(output, "\n", trim: true) == ignored
  end
end
