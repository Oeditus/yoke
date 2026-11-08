defmodule Yoke.PRReview.IdentityTest do
  use ExUnit.Case, async: false
  @moduletag :tmp_dir
  alias Yoke.Json
  alias Yoke.PRReview
  alias Yoke.PRReview.Context
  alias Yoke.Test.ReviewFixture, as: Fixture

  setup %{tmp_dir: dir} do
    upstream = Fixture.repository(Path.join(dir, "upstream"))
    repo = Path.join(dir, "checkout")
    Fixture.git(dir, ["clone", "-q", "--no-local", "--branch", "main", upstream.repo, repo])
    Fixture.git(repo, ["branch", "feature", upstream.base])
    File.write!(Path.join(upstream.repo, "sample.ex"), "new_pr_value\n")
    Fixture.commit(upstream.repo, "new PR head")
    head = Fixture.git(upstream.repo, ["rev-parse", "HEAD"])

    Fixture.git(repo, [
      "config",
      "url.file://#{upstream.repo}.insteadOf",
      "https://github.com/example/repo.git"
    ])

    bin = Path.join(dir, "bin")
    File.mkdir_p!(bin)

    File.write!(
      Path.join(bin, "pr.json"),
      Json.encode!(%{
        number: 42,
        url: "https://github.com/example/repo/pull/42",
        baseRefName: "main",
        headRefName: "feature",
        baseRefOid: upstream.base,
        headRefOid: head,
        author: %{login: "author"}
      })
    )

    File.write!(Path.join(bin, "gh"), """
    #!/bin/sh
    root="${0%/*}"
    printf '%s\\n' "$*" >> "$root/calls"
    case "$1 $2" in
      "pr view")
        if [ "$3" != "42" ] || [ -f "$root/missing" ]; then exit 1; fi
        /bin/cat "$root/pr.json"
        ;;
      "repo view") printf '%s\\n' 'example/repo' ;;
      "api -X")
        while [ "$#" -gt 0 ]; do
          if [ "$1" = "--input" ]; then /bin/cp "$2" "$root/posted.json"; break; fi
          shift
        done
        if /bin/grep -Eq '"event"[[:space:]]*:[[:space:]]*"APPROVE"' "$root/posted.json"; then
          printf '%s\\n' 'GitHub Actions is not permitted to approve pull requests.' >&2
          exit 1
        fi
        ;;
      "api "*) printf '%s\\n' '[]' ;;
      *) exit 1 ;;
    esac
    """)

    File.chmod!(Path.join(bin, "gh"), 0o755)
    original = System.get_env("PATH")
    System.put_env("PATH", bin <> ":" <> (original || ""))

    on_exit(fn ->
      if original, do: System.put_env("PATH", original), else: System.delete_env("PATH")
    end)

    %{repo: repo, bin: bin, head: head, base: upstream.base, upstream: upstream.repo}
  end

  test "clean pinned CR verdicts publish when GitHub Actions cannot approve PRs", %{
    repo: repo,
    bin: bin,
    head: head
  } do
    assert {:ok, context} = Context.resolve("42", repo)
    body = PRReview.build_pr_comment_body([], "", cwd: repo)

    assert {:error, message} = PRReview.post_context_review(context, [], body, "APPROVE")
    assert message =~ "GitHub Actions is not permitted to approve pull requests."
    assert message =~ "No fallback comment was posted."

    endorsement = %{
      id: 1,
      file: "sample.ex",
      line: 1,
      title: "Clear contract",
      description: "The implementation is easy to follow.",
      kind: "endorsement",
      severity: "info",
      fix_suggestion: ""
    }

    for findings <- [[], [endorsement]] do
      body = PRReview.build_pr_comment_body(findings, "", cwd: repo)
      assert {:ok, %{event: "COMMENT"}} = PRReview.post_context_review(context, findings, body)
      posted = bin |> Path.join("posted.json") |> File.read!() |> Json.decode!()
      assert posted["event"] == "COMMENT"
      assert posted["body"] =~ "**Code review: Approved**"
      assert posted["commit_id"] == head
      assert posted["body"] =~ "No actionable issues found."
    end
  end

  test "PR review fetches exact remote commits instead of stale local branches", %{
    repo: repo,
    head: head,
    base: base
  } do
    assert {:ok, context} = Context.resolve("42", repo)
    assert context.pr_number == "42"
    assert context.repository == "example/repo"
    assert context.head_sha == head
    assert context.base_sha == base
    assert context.raw_diff =~ "+new_pr_value"
    assert {:ok, ^base} = Yoke.Git.resolve_revision("feature", repo)
    assert File.read!(Path.join(repo, "sample.ex")) == "old_value\n"
    assert Fixture.git(repo, ["branch", "--show-current"]) == "main"
  end

  test "failed numeric lookup never substitutes the checkout HEAD", %{repo: repo, bin: bin} do
    File.write!(Path.join(bin, "missing"), "")
    assert {:error, reason} = Context.resolve("42", repo)
    assert reason =~ "gh pr view failed"
    refute File.exists?(Path.join(bin, "posted.json"))
  end

  test "posting preserves numeric PR identity and the exact reviewed head", %{
    repo: repo,
    bin: bin,
    head: head
  } do
    assert {:ok, context} = Context.resolve("42", repo)

    finding = %{
      id: 1,
      file: "sample.ex",
      line: 1,
      title: "A regression",
      description: "The changed behavior breaks a caller.",
      kind: "issue",
      severity: "high",
      fix_suggestion: "Restore the contract."
    }

    body = PRReview.build_pr_comment_body([finding], "", cwd: repo)
    assert {:ok, %{number: "42"}} = PRReview.post_context_review(context, [finding], body)
    posted = bin |> Path.join("posted.json") |> File.read!() |> Json.decode!()
    assert posted["commit_id"] == head
    assert posted["event"] == "REQUEST_CHANGES"
    assert [%{"path" => "sample.ex", "line" => 1, "side" => "RIGHT"}] = posted["comments"]
    calls = File.read!(Path.join(bin, "calls"))
    assert calls =~ "repos/example/repo/pulls/42/reviews"
    refute calls =~ "pr view feature"
    refute calls =~ "pr diff"
  end

  test "a moved PR head blocks posting before any external write", %{repo: repo, bin: bin} do
    assert {:ok, context} = Context.resolve("42", repo)
    path = Path.join(bin, "pr.json")

    metadata =
      path |> File.read!() |> Json.decode!() |> Map.put("headRefOid", String.duplicate("a", 40))

    File.write!(path, Json.encode!(metadata))
    assert {:error, reason} = PRReview.post_context_review(context, [], "Review")
    assert reason =~ "changed since review"
    refute File.exists?(Path.join(bin, "posted.json"))
  end

  test "changing PR host or identity blocks posting even for identical commits", %{
    repo: repo,
    bin: bin
  } do
    assert {:ok, context} = Context.resolve("42", repo)
    path = Path.join(bin, "pr.json")

    metadata =
      path
      |> File.read!()
      |> Json.decode!()
      |> Map.put("url", "https://other.example.invalid/example/repo/pull/42")

    File.write!(path, Json.encode!(metadata))
    assert {:error, _} = PRReview.post_context_review(context, [], "Review")
    refute File.exists?(Path.join(bin, "posted.json"))
  end

  test "enterprise PR fetches preserve a matching SSH origin", %{
    repo: repo,
    bin: bin,
    upstream: upstream,
    head: head
  } do
    Fixture.git(repo, [
      "remote",
      "set-url",
      "origin",
      "git@github.enterprise.test:example/repo.git"
    ])

    path = Path.join(bin, "pr.json")

    metadata =
      path
      |> File.read!()
      |> Json.decode!()
      |> Map.put("url", "https://github.enterprise.test/example/repo/pull/42")

    File.write!(path, Json.encode!(metadata))
    ssh = Path.join(bin, "test-ssh")
    File.write!(ssh, "#!/bin/sh\nexec git upload-pack '#{upstream}'\n")
    File.chmod!(ssh, 0o755)
    original = Map.new(~w(GIT_SSH_COMMAND GIT_SSH_VARIANT), &{&1, System.get_env(&1)})
    System.put_env("GIT_SSH_COMMAND", ssh)
    System.put_env("GIT_SSH_VARIANT", "ssh")

    on_exit(fn ->
      Enum.each(original, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end)

    assert {:ok, context} = Context.resolve("42", repo)
    assert context.head_sha == head
    assert context.raw_diff =~ "new_pr_value"
  end

  test "a local review never acquires another PR identity", %{repo: repo} do
    assert {:ok, context} = Context.resolve("HEAD~1 HEAD", repo <> "/../upstream")
    assert context.pr_number == nil
    assert context.repository == nil
  end
end
