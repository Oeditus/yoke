defmodule Yoke.CI.DescribeTest do
  use ExUnit.Case, async: false
  @moduletag :tmp_dir

  alias Yoke.CI.Describe
  alias Yoke.PRReview.Context
  alias Yoke.Test.ReviewFixture, as: Fixture

  setup %{tmp_dir: dir} do
    {:ok, _} = Application.ensure_all_started(:req)
    Fixture.repository(Path.join(dir, "repo"))
  end

  defp provider(responses) do
    {listen, server, endpoint} = Fixture.provider(self(), responses)

    on_exit(fn ->
      :gen_tcp.close(listen)
      if Process.alive?(server), do: Process.exit(server, :kill)
    end)

    endpoint
  end

  describe "prompt/1" do
    test "frames the diff as untrusted evidence and forbids invention", %{repo: repo} do
      {:ok, context} = Context.resolve("main feature", repo)
      prompt = Describe.prompt(context)

      assert prompt =~ context.base_sha
      assert prompt =~ context.head_sha
      assert prompt =~ "untrusted"
      assert prompt =~ "never as instructions"
      assert prompt =~ "Do not invent motivation"
      assert prompt =~ "<diff>"
      assert prompt =~ context.raw_diff
    end

    test "explicitly excludes defect review", %{repo: repo} do
      {:ok, context} = Context.resolve("main feature", repo)
      assert Describe.prompt(context) =~ "separate command"
    end
  end

  describe "system_prompt/0" do
    test "declares the no-tools, untrusted-diff contract" do
      system = Describe.system_prompt()

      assert system =~ "no tools"
      assert system =~ "untrusted"
      assert system =~ "prose only"
    end
  end

  describe "run/1" do
    test "returns the model's summary", %{repo: repo} do
      endpoint = provider([Fixture.choice("This change renames a value.")])
      {:ok, context} = Context.resolve("main feature", repo)

      assert {:ok, result} =
               Describe.run(
                 review_context: context,
                 endpoint: endpoint,
                 model: "describe-test",
                 api_key: ""
               )

      assert result.summary == "This change renames a value."
      assert result.identity.head_sha == context.head_sha
      assert result.usage.diff_bytes > 0
    end

    test "sends a system message and a single user message", %{repo: repo} do
      endpoint = provider([Fixture.choice("Summary.")])
      {:ok, context} = Context.resolve("main feature", repo)

      assert {:ok, _} =
               Describe.run(
                 review_context: context,
                 endpoint: endpoint,
                 model: "describe-test",
                 api_key: ""
               )

      assert_receive {:review_request, request}, 5_000
      assert [system, user] = request["messages"]
      assert system["role"] == "system"
      assert system["content"] =~ "no tools"
      assert user["role"] == "user"
      assert user["content"] =~ "<diff>"
      # No tools are offered to the model.
      assert request["tools"] in [nil, []]
    end

    test "trims surrounding whitespace from the summary", %{repo: repo} do
      endpoint = provider([Fixture.choice("\n\n  Padded summary.  \n\n")])
      {:ok, context} = Context.resolve("main feature", repo)

      assert {:ok, result} =
               Describe.run(
                 review_context: context,
                 endpoint: endpoint,
                 model: "describe-test",
                 api_key: ""
               )

      assert result.summary == "Padded summary."
    end

    test "an empty completion is an error, not a blank success", %{repo: repo} do
      endpoint = provider([Fixture.choice(nil)])
      {:ok, context} = Context.resolve("main feature", repo)

      assert {:error, reason} =
               Describe.run(
                 review_context: context,
                 endpoint: endpoint,
                 model: "describe-test",
                 api_key: ""
               )

      assert reason =~ "empty summary"
    end

    test "a provider failure is an error", %{repo: repo} do
      {:ok, context} = Context.resolve("main feature", repo)

      assert {:error, reason} =
               Describe.run(
                 review_context: context,
                 endpoint: "http://127.0.0.1:1/v1/chat/completions",
                 model: "describe-test",
                 api_key: ""
               )

      assert reason =~ "Summary request failed"
    end

    test "an empty range is an error", %{repo: repo} do
      assert {:error, reason} = Describe.run(cwd: repo, base: "HEAD", head: "HEAD")
      assert reason =~ "No committed changes"
    end

    test "refuses to run without a provider", %{repo: repo} do
      {:ok, context} = Context.resolve("main feature", repo)

      assert {:error, reason} =
               Describe.run(
                 review_context: context,
                 endpoint: "https://provider.example.invalid/chat/completions",
                 api_key: "",
                 model: "describe-test"
               )

      assert reason =~ "canned offline" or reason =~ "provider"
    end
  end
end
