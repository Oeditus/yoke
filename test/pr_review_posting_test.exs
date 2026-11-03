defmodule Yoke.PRReviewPostingTest do
  use ExUnit.Case, async: false

  alias Yoke.Json
  alias Yoke.PRReview
  alias Yoke.PRReview.Markdown

  setup do
    directory =
      Path.join(System.tmp_dir!(), "yoke-gh-review-#{System.unique_integer([:positive])}")

    File.mkdir_p!(directory)
    original_path = System.get_env("PATH")

    File.write!(Path.join(directory, "gh"), """
    #!/bin/sh
    root="${0%/*}"
    case "$1 $2" in
      "pr view")
        printf '%s\\n' '{"number":42,"url":"https://github.com/example/repo/pull/42"}'
        ;;
      "repo view")
        printf '%s\\n' 'example/repo'
        ;;
      "api -X")
        while [ "$#" -gt 0 ]; do
          if [ "$1" = "--input" ]; then
            /bin/cp "$2" "$root/payload.json"
            break
          fi
          shift
        done
        if [ -f "$root/fail-api" ]; then
          exit 1
        fi
        ;;
      "pr comment"|"pr review")
        if [ "$2" = "comment" ] && [ -f "$root/fail-comment" ]; then
          exit 1
        fi
        while [ "$#" -gt 0 ]; do
          if [ "$1" = "--body" ]; then
            printf '%s' "$2" > "$root/comment.md"
            break
          fi
          shift
        done
        ;;
      *)
        exit 1
        ;;
    esac
    """)

    File.chmod!(Path.join(directory, "gh"), 0o755)
    System.put_env("PATH", directory <> ":" <> (original_path || ""))

    on_exit(fn ->
      if original_path, do: System.put_env("PATH", original_path), else: System.delete_env("PATH")
      File.rm_rf!(directory)
    end)

    %{directory: directory}
  end

  test "sanitizes the actual atomic payload before invoking gh", %{directory: directory} do
    payload = %{
      "event" => "COMMENT",
      "body" => "## \u{1FAA2} Review from Alice\nNotes \u{1F680} :warning:",
      "comments" => [
        %{"path" => "lib/test.ex", "line" => 1, "body" => "Review \u2764\uFE0F :+1:"}
      ]
    }

    assert {:ok, %{number: "42"}} = PRReview.post_atomic_review("42", payload, directory)
    assert {:ok, posted} = directory |> Path.join("payload.json") |> File.read!() |> Json.decode()
    assert posted["body"] == "## \u{1FAA2} Review from Alice\nNotes  "
    assert [%{"body" => "Review  "}] = posted["comments"]
  end

  test "atomic failure falls back to an emoji-free PR comment", %{directory: directory} do
    File.write!(Path.join(directory, "fail-api"), "")
    payload = %{"event" => "COMMENT", "body" => "Notes \u{1F680} :warning:", "comments" => []}

    assert {:ok, %{fallback_comment: true}} =
             PRReview.post_atomic_review("42", payload, directory)

    assert File.read!(Path.join(directory, "comment.md")) == "Notes  "
  end

  test "direct posting and its review fallback enforce the same policy", %{directory: directory} do
    body = "## \u{1FAA2} Review from Alice\nNotes \u{1F680} :warning:"

    for fail_comment <- [false, true] do
      if fail_comment, do: File.write!(Path.join(directory, "fail-comment"), "")
      assert {:ok, %{number: "42"}} = PRReview.post_to_github_pr("42", body, directory)
      posted = File.read!(Path.join(directory, "comment.md"))
      assert posted == Markdown.sanitize_review_body(body)
    end
  end
end
