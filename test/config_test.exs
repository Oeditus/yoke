defmodule Yoke.ConfigTest do
  use ExUnit.Case, async: true

  alias Yoke.Config

  test "loads config with default values" do
    config = Config.load_config()
    assert is_map(config)
    assert Map.has_key?(config, "model")
  end

  test "defaults per-million-token prices to DeepSeek V3 rates" do
    config = Config.load_config()
    assert config["price_per_million_prompt_tokens"] == 0.14
    assert config["price_per_million_completion_tokens"] == 0.28
  end

  test "allows overriding per-million-token prices in config" do
    tmp_dir =
      Path.join(System.tmp_dir!(), "config_price_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)

    cfg = %{
      "price_per_million_prompt_tokens" => 1.0,
      "price_per_million_completion_tokens" => 2.0
    }

    assert :ok = Config.save_config(cfg, tmp_dir)
    loaded = Config.load_config(tmp_dir)
    assert loaded["price_per_million_prompt_tokens"] == 1.0
    assert loaded["price_per_million_completion_tokens"] == 2.0

    File.rm_rf!(tmp_dir)
  end

  test "defaults max_tool_depth to 1000 and allows workspace override" do
    assert Config.load_config()["max_tool_depth"] == 1000

    tmp_dir =
      Path.join(System.tmp_dir!(), "config_depth_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)
    assert :ok = Config.save_config(%{"max_tool_depth" => 250}, tmp_dir)
    assert Config.load_config(tmp_dir)["max_tool_depth"] == 250

    File.rm_rf!(tmp_dir)
  end

  test "defaults plan gate to enabled with threshold 2" do
    config = Config.load_config()
    assert config["plan_gate_enabled"] == true
    assert config["plan_gate_threshold"] == 2
  end

  test "allows overriding plan gate defaults in config" do
    tmp_dir =
      Path.join(System.tmp_dir!(), "config_plangate_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)

    cfg = %{"plan_gate_enabled" => false, "plan_gate_threshold" => 5}
    assert :ok = Config.save_config(cfg, tmp_dir)

    loaded = Config.load_config(tmp_dir)
    assert loaded["plan_gate_enabled"] == false
    assert loaded["plan_gate_threshold"] == 5

    File.rm_rf!(tmp_dir)
  end

  test "defaults max_tokens to nil and allows workspace override" do
    # By default no per-request max_tokens is set, so the provider's own
    # default (rather than a hardcoded value) applies for each request.
    assert Config.load_config()["max_tokens"] == nil

    tmp_dir =
      Path.join(System.tmp_dir!(), "config_maxtokens_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)
    assert :ok = Config.save_config(%{"max_tokens" => 64_000}, tmp_dir)
    assert Config.load_config(tmp_dir)["max_tokens"] == 64_000

    File.rm_rf!(tmp_dir)
  end

  test "discovers project rules if present or returns empty string" do
    rules = Config.discover_project_rules()
    assert is_binary(rules)
  end

  test "saves and reloads custom configuration" do
    tmp_dir = Path.join(System.tmp_dir!(), "config_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)

    cfg = %{"model" => "deepseek-reasoner", "prompt_format" => "custom> "}
    assert :ok = Config.save_config(cfg, tmp_dir)

    loaded = Config.load_config(tmp_dir)
    assert loaded["model"] == "deepseek-reasoner"
    assert loaded["prompt_format"] == "custom> "

    File.rm_rf!(tmp_dir)
  end

  test "sets per-tool permission policy in config" do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "config_perm_test_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)

    assert :ok = Config.set_tool_permission("read_file", "allow", tmp_dir)

    loaded = Config.load_config(tmp_dir)
    assert loaded["tool_permissions"]["read_file"] == "allow"

    File.rm_rf!(tmp_dir)
  end

  test "saves and loads global tool permissions with local overrides" do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "config_global_perm_test_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)

    # Save to global config
    assert {:ok, _} = Config.set_global_tool_permission("glob_tool_test", "allow")

    loaded = Config.load_config(tmp_dir)
    assert loaded["tool_permissions"]["glob_tool_test"] == "allow"

    # Local override wins
    assert :ok = Config.set_tool_permission("glob_tool_test", "deny", tmp_dir)
    loaded_override = Config.load_config(tmp_dir)
    assert loaded_override["tool_permissions"]["glob_tool_test"] == "deny"

    File.rm_rf!(tmp_dir)
  end
end
