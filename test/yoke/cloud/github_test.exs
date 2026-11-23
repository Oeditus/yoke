defmodule Yoke.Cloud.GitHubTest do
  @moduledoc """
  Tests for the review-thread evidence fetcher (`docs/YAAS.md` §4.1).

  All parsing is exercised without a network call: `parse_response/1` is the
  pure seam, and the HTTP path is covered only for its failure contract.
  """
  use ExUnit.Case, async: true

  alias Yoke.Cloud.GitHub

  defp response(threads) do
    %{
      "data" => %{
        "repository" => %{
          "pullRequest" => %{"reviewThreads" => %{"nodes" => threads}}
        }
      }
    }
  end

  defp thread(overrides \\ %{}) do
    Map.merge(
      %{
        "isResolved" => false,
        "comments" => %{
          "nodes" => [
            %{
              "path" => "lib/foo.ex",
              "line" => 42,
              "originalLine" => 42,
              "reactions" => %{"nodes" => []}
            }
          ]
        }
      },
      overrides
    )
  end

  describe "parse_response/1" do
    test "maps a thread's resolution onto its comment anchor" do
      {:ok, evidence} = GitHub.parse_response(response([thread(%{"isResolved" => true})]))

      assert %{resolved: true} = evidence[{"lib/foo.ex", 42}]
    end

    test "counts reactions by content" do
      comment = %{
        "path" => "lib/foo.ex",
        "line" => 42,
        "originalLine" => 42,
        "reactions" => %{"nodes" => [%{"content" => "THUMBS_UP"}, %{"content" => "THUMBS_UP"}]}
      }

      thread = thread(%{"comments" => %{"nodes" => [comment]}})
      {:ok, evidence} = GitHub.parse_response(response([thread]))

      assert evidence[{"lib/foo.ex", 42}].reactions == %{"THUMBS_UP" => 2}
    end

    test "prefers originalLine over line" do
      # `line` moves as the diff is rebased; `originalLine` is where the comment
      # was posted. Preferring `line` would mis-key the evidence against the
      # finding, which the precision report anchors at `originalLine`.
      comment = %{
        "path" => "lib/foo.ex",
        "line" => 40,
        "originalLine" => 42,
        "reactions" => %{"nodes" => []}
      }

      thread = thread(%{"comments" => %{"nodes" => [comment]}})
      {:ok, evidence} = GitHub.parse_response(response([thread]))

      assert Map.has_key?(evidence, {"lib/foo.ex", 42})
      refute Map.has_key?(evidence, {"lib/foo.ex", 40})
    end

    test "falls back to line when originalLine is absent" do
      comment = %{
        "path" => "lib/foo.ex",
        "line" => 40,
        "originalLine" => nil,
        "reactions" => %{"nodes" => []}
      }

      thread = thread(%{"comments" => %{"nodes" => [comment]}})
      {:ok, evidence} = GitHub.parse_response(response([thread]))

      assert Map.has_key?(evidence, {"lib/foo.ex", 40})
    end

    test "skips a comment with no usable anchor" do
      comment = %{
        "path" => "lib/foo.ex",
        "line" => nil,
        "originalLine" => nil,
        "reactions" => %{"nodes" => []}
      }

      thread = thread(%{"comments" => %{"nodes" => [comment]}})
      {:ok, evidence} = GitHub.parse_response(response([thread]))

      assert evidence == %{}
    end

    test "returns an empty map for no threads" do
      assert {:ok, %{}} = GitHub.parse_response(response([]))
    end

    test "a GraphQL error is a failure even with partial data" do
      # A partial evidence map would silently under-report resolutions, which is
      # worse than reporting none: the caller degrades to weaker signals.
      body = Map.put(response([thread()]), "errors", [%{"message" => "rate limited"}])

      assert {:error, reason} = GitHub.parse_response(body)
      assert reason =~ "rate limited"
    end

    test "an unexpected shape is a failure" do
      assert {:error, _reason} = GitHub.parse_response(%{"data" => %{}})
      assert {:error, _reason} = GitHub.parse_response(nil)
    end
  end

  describe "evidence_for/3" do
    test "returns the evidence for a matching anchor" do
      evidence = %{{"lib/foo.ex", 42} => %{resolved: true, reactions: %{}}}

      assert GitHub.evidence_for(evidence, "lib/foo.ex", 42) == %{resolved: true, reactions: %{}}
    end

    test "returns an empty map for a missing anchor" do
      assert GitHub.evidence_for(%{}, "lib/foo.ex", 42) == %{}
    end

    test "tolerates a nil file or line" do
      assert GitHub.evidence_for(%{}, nil, 42) == %{}
      assert GitHub.evidence_for(%{}, "lib/foo.ex", nil) == %{}
    end
  end

  describe "fetch_threads/5 without a token" do
    test "fails without attempting a request" do
      assert {:error, reason} = GitHub.fetch_threads("o", "r", 1, nil)
      assert reason =~ "no GitHub token"
    end

    test "treats an empty token as absent" do
      assert {:error, _reason} = GitHub.fetch_threads("o", "r", 1, "")
    end
  end
end
