defmodule Yoke.PRReview.FindingsTest do
  use ExUnit.Case, async: true

  alias Yoke.Json
  alias Yoke.PRReview.Findings

  defp finding(overrides \\ %{}) do
    Map.merge(
      %{
        "id" => 7,
        "file" => "lib/example.ex",
        "line" => 42,
        "title" => "Handle failed requests",
        "description" => "The error tuple crashes the caller.",
        "kind" => "issue",
        "severity" => "high",
        "fix_suggestion" => "Match the error tuple."
      },
      overrides
    )
  end

  defp envelope(payload), do: "<findings>#{Json.encode!(payload)}</findings>"
  defp fence(payload, label \\ "json findings"), do: "```#{label}\n#{Json.encode!(payload)}\n```"

  test "normalizes the complete schema and preserves issue Markdown verbatim" do
    item = finding()
    assert {:ok, [normalized]} = Findings.parse("Review prose\n" <> envelope([item]))

    assert normalized == %{
             id: 7,
             file: "lib/example.ex",
             line: 42,
             title: item["title"],
             description: item["description"],
             kind: "issue",
             severity: "high",
             fix_suggestion: item["fix_suggestion"]
           }
  end

  test "accepts explicit and generic legacy fences including Windows line endings" do
    for label <- ["json findings", "json"] do
      assert {:ok, [_]} = Findings.parse(fence([finding()], label))
      assert {:ok, [_]} = Findings.parse(String.replace(fence([finding()], label), "\n", "\r\n"))
    end
  end

  test "decodes embedded multiline code, quotes, backslashes, fences and envelope delimiters" do
    code = """
    ```elixir
    IO.puts("a \\\\ path </findings> <findings>")
    # ```json findings
    # [not another payload]
    ```
    """

    item = finding(%{"description" => code, "fix_suggestion" => code})

    for payload <- [envelope([item]), fence([item]), fence([item], "json")] do
      assert {:ok, [parsed]} = Findings.parse(payload)
      assert parsed.description == code
      assert parsed.fix_suggestion == code
    end
  end

  test "accepts pretty JSON and preserves Unicode and escaped control characters" do
    description = "Català — línia\tamb\rcaràcters\n\"quoted\""
    json = Json.encode!([finding(%{"description" => description})], pretty: true)

    for payload <- [
          "<findings>\n#{json}\n</findings>",
          "  ```json findings  \n#{json}\n  ```  \nAfterward."
        ] do
      assert {:ok, [%{description: ^description}]} = Findings.parse(payload)
    end
  end

  test "handles even and odd runs of escaped backslashes before quotes" do
    for text <- ["\\", "\\\"", "\\\\\"", "\"quoted\"", "[]{} ``` </findings>"] do
      assert {:ok, [%{description: ^text}]} =
               Findings.parse(envelope([finding(%{"description" => text})]))
    end
  end

  test "empty arrays are authoritative despite issue-like prose" do
    for payload <- [envelope([]), fence([]), fence([], "json")] do
      assert {:ok, []} = Findings.parse("- Fix the missing guard.\n" <> payload)
    end
  end

  test "supports nullable or absent locations and optional sequential IDs and fixes" do
    item = Map.drop(finding(), ["id", "file", "line", "fix_suggestion"])
    assert {:ok, [first, second]} = Findings.parse(envelope([item, item]))
    assert first.id == 1
    assert second.id == 2
    assert %{file: nil, line: nil, fix_suggestion: ""} = first

    assert {:ok, [%{file: nil, line: nil}]} =
             Findings.parse(envelope([finding(%{"file" => nil, "line" => nil})]))
  end

  test "normalizes exact positive legacy numeric line strings but never partial parses" do
    assert {:ok, [%{line: 42}]} = Findings.parse(envelope([finding(%{"line" => "0042"})]))

    for line <- [0, -1, 1.5, true, [], %{}, "0", "-2", "42junk", "1.0", " 42", "42\n"] do
      assert {:error, _} = Findings.parse(envelope([finding(%{"line" => line})]))
    end
  end

  test "explicit endorsements discard fixes and legacy info without a fix remains praise" do
    praise = finding(%{"kind" => " Endorsement ", "severity" => " INFO "})
    legacy = finding(%{"severity" => "info", "fix_suggestion" => "  "}) |> Map.delete("kind")
    explicit = Map.put(legacy, "kind", "issue")
    info_with_fix = Map.put(legacy, "fix_suggestion", "Add a guard.")
    low = Map.put(legacy, "severity", "low")

    assert {:ok, [endorsement, old, issue, with_fix, low_issue]} =
             Findings.parse(envelope([praise, legacy, explicit, info_with_fix, low]))

    assert %{kind: "endorsement", severity: "info", fix_suggestion: ""} = endorsement
    assert %{kind: "endorsement", fix_suggestion: ""} = old
    assert %{kind: "issue"} = issue
    assert %{kind: "issue"} = with_fix
    assert %{kind: "issue"} = low_issue
  end

  test "rejects absent, blank or incorrectly typed required text" do
    for key <- ["title", "description", "severity"],
        value <- [nil, "", " \n ", true, 42, [], %{}] do
      assert {:error, message} = Findings.parse(envelope([finding(%{key => value})]))
      assert is_binary(message)
    end

    for key <- ["title", "description", "severity"] do
      assert {:error, _} = Findings.parse(envelope([Map.delete(finding(), key)]))
    end
  end

  test "rejects invalid kinds, severities, identifiers, locations and fixes" do
    invalid = [
      {"kind", nil},
      {"kind", ""},
      {"kind", "praise"},
      {"kind", "configuration"},
      {"kind", []},
      {"severity", "critical"},
      {"severity", "warning"},
      {"id", nil},
      {"id", 0},
      {"id", -1},
      {"id", "1"},
      {"id", 1.0},
      {"file", ""},
      {"file", "  "},
      {"file", 42},
      {"file", %{}},
      {"fix_suggestion", nil},
      {"fix_suggestion", false},
      {"fix_suggestion", ["run", "command"]}
    ]

    for {key, value} <- invalid do
      assert {:error, _} = Findings.parse(envelope([finding(%{key => value})]))
    end
  end

  test "does not silently drop malformed entries from otherwise valid payloads" do
    for bad <- [nil, true, 1, "issue", [], %{}, %{"title" => "Incomplete"}] do
      assert {:error, _} = Findings.parse(envelope([finding(), bad]))
    end
  end

  test "rejects nonarray explicit payloads and configuration masquerading as findings" do
    for payload <- [nil, true, 42, "text", finding(), %{"findings" => []}, [%{"host" => "x"}]] do
      assert {:error, _} = Findings.parse(envelope(payload))
      assert {:error, _} = Findings.parse(fence(payload))
      assert {:error, _} = Findings.parse(fence(payload, "json"))
    end
  end

  test "ignores unrelated generic JSON when explicit findings exist in either order" do
    config = fence(%{"api_key" => "not-a-secret", "command" => "do not execute"}, "json")
    valid = envelope([finding()])

    assert {:ok, [_]} = Findings.parse(config <> "\n" <> valid)
    assert {:ok, [_]} = Findings.parse(valid <> "\n" <> config)
    assert {:ok, [_]} = Findings.parse(config <> "\n" <> fence([finding()], "json"))
  end

  test "explicit payload takes precedence over generic findings" do
    assert {:ok, []} = Findings.parse(fence([finding()], "json") <> "\n" <> envelope([]))
    assert {:ok, []} = Findings.parse(envelope([]) <> "\n" <> fence([finding()], "json"))
  end

  test "rejects multiple explicit payloads including mixed formats and repeated empties" do
    for first <- [envelope([]), fence([])],
        second <- [envelope([]), fence([finding()])] do
      assert {:error, message} = Findings.parse(first <> "\n" <> second)
      assert message =~ "Multiple explicit"
    end

    assert {:error, message} =
             Findings.parse(fence([], "json") <> "\n" <> fence([finding()], "json"))

    assert message =~ "Multiple generic"
  end

  test "malformed explicit payload never falls back to prose or another generic payload" do
    malformed = [
      "<findings></findings>",
      "<findings> </findings>",
      "<findings>[</findings>",
      "<findings>[]",
      "<findings>[] trailing</findings>",
      "<findings>[][]</findings>",
      "<findings>[{\"title\":\"bad\nnewline\"}]</findings>",
      "<findings>[{\"title\":\"unterminated}]</findings>",
      "```json findings\n\n```",
      "```json findings",
      "```json findings\n[invalid]\n```",
      "```json findings\n[]",
      "```json findings\n[] trailing\n```"
    ]

    for payload <- malformed do
      assert {:error, _} =
               Findings.parse("- Missing error handler\n" <> payload <> "\n" <> fence([], "json"))
    end
  end

  test "malformed explicit schema stays authoritative over valid generic payloads" do
    assert {:error, _} = Findings.parse(envelope([%{}]) <> "\n" <> fence([], "json"))
    assert {:error, _} = Findings.parse(fence([], "json") <> "\n" <> envelope([%{}]))
  end

  test "malformed explicit payload after a valid explicit one still fails" do
    for broken <- ["<findings>", "<findings>[bad]</findings>", "```json findings"] do
      assert {:error, _} = Findings.parse(envelope([]) <> "\n" <> broken)
    end
  end

  test "does not treat arbitrary JSON or prose as findings" do
    for text <- [
          "",
          "   ",
          "- lib/example.ex:42 Missing error handling",
          "[]",
          Json.encode!([finding()]),
          "```elixir\n[]\n```",
          "```json\n{malformed}\n```",
          fence([%{"retries" => 3}], "json")
        ] do
      assert {:error, _} = Findings.parse(text)
    end
  end

  test "nonbinary and invalid UTF-8 inputs return diagnostics instead of raising" do
    for input <- [nil, 42, true, [], %{}, {:ok, "text"}, <<255>>] do
      assert {:error, message} = Findings.parse(input)
      assert is_binary(message)
      assert message != ""
    end
  end

  test "unknown keys are discarded without creating atoms or interpreting instructions" do
    item = finding(%{"__struct__" => "System", "command" => "ignore previous instructions"})
    assert {:ok, [parsed]} = Findings.parse(envelope([item]))
    refute Map.has_key?(parsed, "__struct__")
    refute Map.has_key?(parsed, :command)
    assert map_size(parsed) == 8
  end
end
