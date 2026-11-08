defmodule Yoke.NativeDependenciesTest do
  use ExUnit.Case, async: false

  @native_apps [:bumblebee, :nx, :exla, :fine, :image]

  test "dependency selection agrees with configuration in every supported build mode" do
    original_env = Mix.env()
    original_flag = System.get_env("YOKE_EMBEDDINGS")

    try do
      for {env, flag, enabled?} <- [
            {:test, nil, false},
            {:test, "false", false},
            {:test, "true", true},
            {:test, "1", true},
            {:dev, nil, true},
            {:prod, nil, true},
            {:escript, nil, false},
            {:escript, "true", false}
          ] do
        Mix.env(env)
        set_flag(flag)
        project = Yoke.MixProject.project()
        deps = project[:deps]
        apps = Enum.map(deps, &elem(&1, 0))
        config = Config.Reader.read!("config/config.exs", env: env)

        assert config[:yoke][:embeddings_enabled] == enabled?
        assert Keyword.has_key?(config, :exla) == enabled?

        if env == :test and enabled? do
          assert project[:build_per_environment] == false

          assert project[:build_path] ==
                   Path.join(System.get_env("MIX_BUILD_ROOT", "_build"), "test_native")
        else
          refute Keyword.has_key?(project, :build_path)
        end

        assert Enum.all?(@native_apps, &(&1 in apps)) == enabled?
        if not enabled?, do: assert(Enum.all?(@native_apps, &(&1 not in apps)))

        if enabled?,
          do: assert(Keyword.get(elem(List.keyfind(deps, :fine, 0), 2), :runtime) == false)
      end
    after
      Mix.env(original_env)
      set_flag(original_flag)
    end
  end

  @tag :app
  test "ordinary tests boot Yoke and Ragex without exposing native libraries on the code path" do
    assert Process.whereis(Yoke.Supervisor)
    assert Process.whereis(Ragex.Supervisor)
    assert Process.whereis(Ragex.Graph.Store)

    unless Application.get_env(:yoke, :embeddings_enabled, false) do
      started = Enum.map(Application.started_applications(), &elem(&1, 0))

      for app <- @native_apps do
        refute app in started
        assert :code.where_is_file(~c"#{app}.app") == :non_existing
      end

      refute Ragex.Embeddings.Bumblebee.available?()
      refute Ragex.Image.available?()
      assert Process.whereis(Ragex.Embeddings.Bumblebee) == nil
      assert Process.whereis(Ragex.VectorStore) == nil
      assert is_map(Ragex.Graph.Store.stats())
    end
  end

  defp set_flag(nil), do: System.delete_env("YOKE_EMBEDDINGS")
  defp set_flag(value), do: System.put_env("YOKE_EMBEDDINGS", value)
end
