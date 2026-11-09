defmodule Yoke.PRReview.CLITest do
  use ExUnit.Case, async: false
  @moduletag :tmp_dir

  import ExUnit.CaptureIO
  alias Yoke.PRReview.CLI
  alias Yoke.Test.ReviewFixture

  defmodule Interaction do
    @behaviour Yoke.Interaction
    @impl true
    def ask(kind, context) do
      send(self(), {:review_confirmation, kind, context})
      Process.get(:review_decision, fn -> :deny end).()
    end
  end

  defmodule SessionStub do
    use GenServer
    def start_link(owner), do: GenServer.start_link(__MODULE__, owner)
    @impl true
    def init(owner), do: {:ok, owner}
    @impl true
    def handle_call({:apply_review_fixes, context, prompt}, _from, owner) do
      send(owner, {:applied_fixes, context, prompt})
      {:reply, {:ok, %{content: "Mock fixes completed."}}, owner}
    end
  end

  setup %{tmp_dir: directory} do
    prior = Application.get_env(:yoke, :interaction)
    Application.put_env(:yoke, :interaction, Interaction)

    on_exit(fn ->
      if is_nil(prior),
        do: Application.delete_env(:yoke, :interaction),
        else: Application.put_env(:yoke, :interaction, prior)
    end)

    fixture = ReviewFixture.repository(Path.join(directory, "repo"))
    {:ok, context} = Yoke.PRReview.Context.from_branches(fixture.base, fixture.head, fixture.repo)
    %{context: context, repo: fixture.repo}
  end

  test "denial uses Interaction and never starts a fix turn", %{context: context, repo: repo} do
    output =
      File.cd!(repo, fn ->
        capture_io(fn -> CLI.handle_review_fixes(nil, context, "Fix the regression.") end)
      end)

    assert output =~ "Fix the regression."
    assert_receive {:review_confirmation, :review_fix, %{cwd: ^repo, options: [_, _]}}
    refute_receive {:applied_fixes, _, _}
  end

  test "invalid initial checkout never asks for approval", %{context: context, repo: repo} do
    File.write!(Path.join(repo, "sample.ex"), "dirty\n")
    Process.put(:review_decision, fn -> flunk("must not ask for an unsafe checkout") end)

    output =
      File.cd!(repo, fn ->
        capture_io(fn -> CLI.handle_review_fixes(nil, context, "Fix it.") end)
      end)

    assert output =~ "Fixes were not applied"
    refute_receive {:review_confirmation, _, _}
  end

  test "checkout is verified again after approval before edits", %{context: context, repo: repo} do
    Process.put(:review_decision, fn ->
      File.write!(Path.join(repo, "sample.ex"), "changed while asking\n")
      :approve
    end)

    output =
      File.cd!(repo, fn ->
        capture_io(fn -> CLI.handle_review_fixes(nil, context, "Fix it.") end)
      end)

    assert_receive {:review_confirmation, :review_fix, _}
    assert output =~ "Fixes were not applied"
    refute_receive {:applied_fixes, _, _}
  end

  test "approved fixes use the pinned context and render the turn result", %{
    context: context,
    repo: repo
  } do
    Process.put(:review_decision, fn -> :approve end)
    pid = start_supervised!({SessionStub, self()})

    output =
      File.cd!(repo, fn ->
        capture_io(fn -> CLI.handle_review_fixes(pid, context, "Fix it.") end)
      end)

    assert_receive {:applied_fixes, ^context, prompt}
    assert prompt =~ "Repository: #{repo}"
    assert prompt =~ "Reviewed head: #{context.head_sha}"
    assert prompt =~ "Fix it."
    assert output =~ "Mock fixes completed."
  end

  test "pattern recording requires approval and writes only to the reviewed repository", %{
    context: context,
    repo: repo
  } do
    path = Path.join(repo, ".yoke/review_patterns.md")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "# Review patterns\n")

    finding = %{
      title: "Lost update",
      description: "Preserve concurrent edits.",
      file: "sample.ex",
      line: 1
    }

    capture_io(fn -> CLI.maybe_record_review_patterns([finding], context) end)
    assert File.read!(path) == "# Review patterns\n"
    assert_receive {:review_confirmation, :review_fix, %{cwd: ^repo}}

    Process.put(:review_decision, fn -> :approve end)
    output = capture_io(fn -> CLI.maybe_record_review_patterns([finding], context) end)
    assert output =~ "Updated living review patterns"
    assert File.read!(path) =~ "Lost update"
    assert File.read!(path) =~ "Commit #{context.head_sha}"
  end

  test "turn failures render independently of the REPL" do
    assert capture_io(fn -> CLI.print_review_result({:error, "Turn cancelled"}) end) =~
             "Turn cancelled"
  end
end
