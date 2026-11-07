defmodule Yoke.CI.CacheTest do
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)

  for file <- ["action.yml", ".github/workflows/ci.yml", ".github/workflows/ragex-ci.yml"] do
    test "#{file} excludes dllb runtime state and does not restore legacy caches" do
      workflow = YamlElixir.read_from_file!(Path.join(@root, unquote(file)))

      steps =
        case workflow do
          %{"runs" => %{"steps" => steps}} -> steps
          %{"jobs" => jobs} -> Enum.flat_map(jobs, fn {_name, job} -> job["steps"] || [] end)
        end

      caches =
        Enum.filter(steps, fn step ->
          step["name"] == "Restore Ragex and yoke caches"
        end)

      assert [_] = caches

      for %{"with" => config} <- caches do
        paths = String.split(config["path"], "\n", trim: true)
        assert ".ragex" in paths
        assert "!.ragex/**/dllb.instance.json" in paths
        assert "!.ragex/**/*.sock" in paths
        assert config["key"] =~ "-ragex-v2-"
        assert String.trim(config["restore-keys"]) == "${{ runner.os }}-ragex-v2-"
      end
    end
  end
end
