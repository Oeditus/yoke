defmodule Yoke.ProviderTest do
  use ExUnit.Case, async: false
  @moduletag tmp_dir: true

  alias Yoke.Brain.Session
  alias Yoke.Brain.SessionStore
  alias Yoke.Brain.SessionSupervisor
  alias Yoke.Client.DeepSeekAPI
  alias Yoke.Provider

  setup do
    keys =
      ~w(YOKE_PROVIDER DEEPSEEK_MODEL DEEPSEEK_ENDPOINT DEEPSEEK_API_KEY OPENROUTER_BASE_URL OPENROUTER_API_KEY OLLAMA_HOST)

    previous = Map.new(keys, &{&1, System.get_env(&1)})
    Enum.each(keys, &System.delete_env/1)

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end)
  end

  test "DeepSeek profile does not reuse a generic key configured for another endpoint", %{
    tmp_dir: cwd
  } do
    :ok =
      Yoke.Config.save_config(
        %{"endpoint" => "https://openrouter.ai/api/v1", "api_key" => "aggregator-test"},
        cwd
      )

    assert Provider.resolve(provider: "deepseek", cwd: cwd)[:api_key] == nil
  end

  test "local profile ignores remote credentials and ambient endpoint/model", %{tmp_dir: cwd} do
    System.put_env("DEEPSEEK_MODEL", "wrong-model")
    System.put_env("DEEPSEEK_ENDPOINT", "https://example.invalid/v1")
    System.put_env("DEEPSEEK_API_KEY", "deepseek-test")
    System.put_env("OLLAMA_HOST", "http://example.invalid:11434")
    opts = Provider.resolve(provider: "local", api_key: "remote-test", cwd: cwd)

    assert opts[:model] == "devstral-small-2:24b-instruct-2512-q4_K_M"
    assert opts[:endpoint] == "http://127.0.0.1:11434/v1/chat/completions"
    assert opts[:api_key] == "not-needed"
    assert opts[:temperature] == 0.15
    assert opts[:max_context_tokens] == 16_384
    assert opts[:price_per_million_prompt_tokens] == 0.0

    refute Enum.any?(
             DeepSeekAPI.build_headers(DeepSeekAPI.build_config(opts)),
             fn {key, _value} -> key == "Authorization" end
           )
  end

  test "DeepSeek profile ignores aggregator routing and credentials", %{tmp_dir: cwd} do
    System.put_env("OPENROUTER_API_KEY", "aggregator-test")
    System.put_env("OPENROUTER_BASE_URL", "https://example.invalid/v1")
    System.put_env("DEEPSEEK_ENDPOINT", "http://localhost:11434")
    System.put_env("DEEPSEEK_MODEL", "unrelated")
    System.put_env("DEEPSEEK_API_KEY", "deepseek-test")
    opts = Provider.resolve(provider: "deepseek", cwd: cwd)
    assert opts[:api_key] == "deepseek-test"
    assert opts[:model] == "deepseek-flash"
    assert opts[:endpoint] == "https://api.deepseek.com/chat/completions"
  end

  test "local profile rejects a remote endpoint override" do
    assert_raise ArgumentError, ~r/loopback/, fn ->
      Provider.resolve(provider: "local", endpoint: "https://example.invalid/v1")
    end
  end

  test "unknown profile fails rather than reverting to a default" do
    assert_raise ArgumentError, ~r/Unknown provider/, fn ->
      Provider.resolve(provider: "locla")
    end
  end

  test "Qwen profile and explicit model overrides remain local" do
    opts = Provider.resolve(provider: "local-qwen")
    assert opts[:model] == "qwen3-coder:30b-a3b-q4_K_M"
    assert Provider.location(opts[:endpoint]) == "LOCAL"
    assert Provider.resolve(provider: "local", model: "custom-local")[:model] == "custom-local"
  end

  test "environment profile can be overridden explicitly" do
    System.put_env("YOKE_PROVIDER", "local")
    assert Provider.resolve()[:provider] == "local"
    assert Provider.resolve(provider: "deepseek")[:provider] == "deepseek"
  end

  test "legacy endpoint and model overrides are preserved", %{tmp_dir: cwd} do
    System.put_env("DEEPSEEK_MODEL", "legacy-model")
    opts = Provider.resolve(endpoint: "http://localhost:1234", cwd: cwd)
    assert opts[:model] == "legacy-model"
    assert opts[:endpoint] == "http://localhost:1234/v1/chat/completions"
    assert opts[:api_key] == "not-needed"
  end

  test "resolved options do not reread changed environment", %{tmp_dir: cwd} do
    opts = Provider.resolve(provider: "local", cwd: cwd)
    System.put_env("YOKE_PROVIDER", "deepseek")
    assert DeepSeekAPI.build_config(opts).endpoint == opts[:endpoint]
    assert DeepSeekAPI.build_config(opts).api_key == "not-needed"
  end

  test "local request omits DeepSeek-only thinking fields" do
    cfg = DeepSeekAPI.build_config(provider: "local")
    assert cfg.thinking == nil
    assert cfg.reasoning_effort == nil
  end

  test "explicit remote profile without credentials fails instead of mocking" do
    assert {:error, error} =
             DeepSeekAPI.chat_completion([%{"role" => "user", "content" => "hello"}], [],
               provider: "deepseek",
               api_key: "",
               mock: false
             )

    assert error =~ "no API credentials"
  end

  test "switching changes the whole profile and leaves Hands alone", %{tmp_dir: cwd} do
    pid = session(cwd, "deepseek")
    assert {:ok, description} = Session.set_provider(pid, "local")
    assert description =~ "LOCAL"
    opts = Session.provider_options(pid)
    assert opts[:api_key] == "not-needed"
    assert opts[:provider] == "local"
    assert Session.get_info(pid).hands_mode == :local
    assert Session.get_stats(pid).max_context_tokens == 16_384
    assert {:ok, _} = Session.set_provider(pid, "deepseek")
    assert {:ok, "deepseek-flash"} = Session.get_model(pid)
    assert {:error, _} = Session.set_provider(pid, "typo")
    assert {:ok, "deepseek-flash"} = Session.get_model(pid)
  end

  test "provider cannot change during an active turn", %{tmp_dir: cwd} do
    pid = session(cwd, "local")
    :sys.replace_state(pid, &%{&1 | active_turn: %{test: true}})
    assert {:error, _} = Session.set_provider(pid, "deepseek")
    assert {:error, _} = Session.set_endpoint(pid, "https://api.deepseek.com/chat/completions")
    assert Session.provider_options(pid)[:provider] == "local"
    :sys.replace_state(pid, &%{&1 | active_turn: nil})
  end

  test "provider status discloses remote history and does not display credentials", %{
    tmp_dir: cwd
  } do
    pid = session(cwd, "local")

    output =
      ExUnit.CaptureIO.capture_io(fn ->
        Yoke.CLI.Repl.handle_input("/provider deepseek", pid, "test")
      end)

    assert output =~ "REMOTE"
    assert output =~ "conversation history"
    refute output =~ "deepseek-test"
  end

  test "session resume preserves local provider and contains no credential", %{tmp_dir: cwd} do
    pid = session(cwd, "local")
    info = Session.get_info(pid)
    assert {:ok, _} = Session.checkpoint(pid, "local-checkpoint")
    assert {:ok, saved} = SessionStore.load_session(info.session_id, cwd)
    assert saved["provider_options"]["provider"] == "local"
    assert {:ok, path} = SessionStore.save_session(:sys.get_state(pid), cwd)
    refute File.read!(path) =~ "not-needed"
    assert :ok = SessionSupervisor.stop_session(pid)
    {:ok, resumed} = SessionSupervisor.start_session(session_id: info.session_id, cwd: cwd)
    on_exit(fn -> SessionSupervisor.stop_session(resumed) end)
    assert Session.provider_options(resumed)[:provider] == "local"
  end

  test "checkpoint undo restores endpoint and model together", %{tmp_dir: cwd} do
    pid = session(cwd, "local")
    assert {:ok, _} = Session.checkpoint(pid, "local")
    assert {:ok, _} = Session.set_provider(pid, "deepseek")
    assert {:ok, _} = Session.undo(pid)
    opts = Session.provider_options(pid)
    assert opts[:provider] == "local"
    assert opts[:api_key] == "not-needed"
    assert Provider.location(opts[:endpoint]) == "LOCAL"
  end

  @tag skip_in_gha: true
  test "children and compression inherit resolved local options", %{tmp_dir: cwd} do
    pid = session(cwd, "local")
    opts = Session.provider_options(pid)

    assert {:ok, child} =
             SessionSupervisor.start_session(
               Keyword.put(opts, :session_id, "child-#{System.unique_integer([:positive])}")
             )

    on_exit(fn -> SessionSupervisor.stop_session(child) end)
    assert Session.provider_options(child)[:provider] == "local"
    assert {:ok, _} = Session.compact_context(pid)
    assert {:ok, _} = Session.spawn_subagent(pid, "Say hello", async: false)
  end

  @tag skip_in_gha: true
  test "cost incurred remotely is not erased or repriced by switching local", %{tmp_dir: cwd} do
    pid = session(cwd, "deepseek")
    assert {:ok, _} = Session.send_user_message(pid, "Hello")
    cost = Session.get_token_stats(pid).estimated_cost_usd
    assert cost > 0
    assert {:ok, _} = Session.set_provider(pid, "local")
    assert {:ok, _} = Session.send_user_message(pid, "Hello")
    assert Session.get_token_stats(pid).estimated_cost_usd == cost
  end

  test "local HTTP transport serializes tools and parses real tool results", %{tmp_dir: cwd} do
    response = %{
      "choices" => [
        %{
          "finish_reason" => "tool_calls",
          "message" => %{
            "role" => "assistant",
            "content" => nil,
            "tool_calls" => [
              %{
                "id" => "call_test",
                "type" => "function",
                "function" => %{"name" => "add", "arguments" => "{\"a\":17,\"b\":23}"}
              }
            ]
          }
        }
      ]
    }

    {endpoint, listener, server} = http_server(response)

    on_exit(fn ->
      :gen_tcp.close(listener)
      Process.exit(server, :normal)
    end)

    tools = [%{name: "add", description: "Add", parameters: %{"type" => "object"}}]

    assert {:ok, %{tool_calls: [call]}} =
             DeepSeekAPI.chat_completion(
               [%{"role" => "user", "content" => "Add"}],
               tools,
               provider: "local",
               endpoint: endpoint,
               mock: false,
               cwd: cwd
             )

    assert call.arguments == %{"a" => 17, "b" => 23}
    assert_receive {:http_request, request}, 1_000
    refute request =~ "Authorization:"
    refute request =~ "\"thinking\""
    refute request =~ "\"reasoning_effort\""
    assert request =~ "\"tools\""
  end

  test "an unavailable local server returns an error without a remote fallback", %{tmp_dir: cwd} do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, {_, port}} = :inet.sockname(listener)
    :gen_tcp.close(listener)
    id = "local-failure-#{System.unique_integer([:positive])}"

    {:ok, pid} =
      SessionSupervisor.start_session(
        session_id: id,
        cwd: cwd,
        provider: "local",
        endpoint: "http://127.0.0.1:#{port}/v1",
        mock: false
      )

    on_exit(fn -> SessionSupervisor.stop_session(pid) end)
    assert {:error, reason} = Session.send_user_message(pid, "Hello")
    assert reason =~ "no remote fallback"
    assert Session.provider_options(pid)[:provider] == "local"
  end

  @tag skip_in_gha: true
  test "context occupancy is not cumulative API usage", %{tmp_dir: cwd} do
    pid = session(cwd, "local")
    assert {:ok, _} = Session.send_user_message(pid, "Hello")
    assert {:ok, _} = Session.send_user_message(pid, "Hello again")
    stats = Session.get_stats(pid)
    assert stats.context_tokens > 0
    assert stats.context_tokens < stats.total_tokens
  end

  test "workflow meta calls retain the selected local transport", %{tmp_dir: cwd} do
    response = %{
      "choices" => [
        %{
          "finish_reason" => "stop",
          "message" => %{
            "role" => "assistant",
            "content" => "local workflow"
          }
        }
      ]
    }

    {endpoint, listener, server} = http_server(response)

    on_exit(fn ->
      :gen_tcp.close(listener)
      Process.exit(server, :normal)
    end)

    opts = Provider.resolve(provider: "local", endpoint: endpoint, mock: false, cwd: cwd)
    context = %{cwd: cwd, workflow: %{rules_scope: "all"}, provider_options: opts}
    assert {:ok, "local workflow"} = Yoke.Workflow.Engine.ask_llm(context, "Describe")
    assert_receive {:http_request, request}, 1_000
    assert request =~ "devstral-small-2"
    refute request =~ "deepseek-flash"
  end

  test "doctor reports local transport without requiring remote credentials", %{tmp_dir: cwd} do
    report = Yoke.CLI.Doctor.run(cwd, provider: "local")
    check = Enum.find(report.checks, &(&1.category == "AI Provider Credentials"))
    assert check.status == :ok
    assert check.details =~ "LOCAL"
    assert check.details =~ "no API key required"
  end

  test "provider flags can precede headless subcommands" do
    assert {"review", ["--provider", "local", "--base", "main"]} =
             Yoke.CLI.Main.split_subcommand(["--provider", "local", "review", "--base", "main"])
  end

  defp session(cwd, provider) do
    id = "provider-test-#{System.unique_integer([:positive])}"

    {:ok, pid} =
      SessionSupervisor.start_session(session_id: id, cwd: cwd, provider: provider, mock: true)

    on_exit(fn ->
      if Process.alive?(pid), do: SessionSupervisor.stop_session(pid)
    end)

    pid
  end

  defp http_server(response) do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, {_, port}} = :inet.sockname(listener)
    owner = self()

    pid =
      spawn(fn ->
        {:ok, socket} = :gen_tcp.accept(listener)
        request = read_request(socket, "")
        send(owner, {:http_request, request})
        body = Yoke.Json.encode!(response)

        :gen_tcp.send(
          socket,
          "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: #{byte_size(body)}\r\nConnection: close\r\n\r\n" <>
            body
        )

        :gen_tcp.close(socket)
      end)

    {"http://127.0.0.1:#{port}/v1", listener, pid}
  end

  defp read_request(socket, buffer) do
    case String.split(buffer, "\r\n\r\n", parts: 2) do
      [headers, body] ->
        [_, length] = Regex.run(~r/content-length: (\d+)/i, headers)

        if byte_size(body) >= String.to_integer(length) do
          buffer
        else
          {:ok, more} = :gen_tcp.recv(socket, 0, 5_000)
          read_request(socket, buffer <> more)
        end

      _ ->
        {:ok, more} = :gen_tcp.recv(socket, 0, 5_000)
        read_request(socket, buffer <> more)
    end
  end
end
