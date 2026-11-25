defmodule Yoke.Brain.SessionMetadataTest do
  use ExUnit.Case, async: true

  alias Yoke.Brain.SessionLmml
  alias Yoke.Brain.SessionMetadata
  alias Yoke.Brain.SessionStore

  @moduletag :tmp_dir

  defp state(id \\ "metadata") do
    %{
      session_id: id,
      model: "deepseek-flash",
      step_count: 7,
      messages: [
        %{"role" => "system", "content" => "System"},
        %{"role" => "user", "content" => "Find the bottleneck"},
        %{"role" => "assistant", "content" => "Result"}
      ],
      snapshots: []
    }
  end

  defp embed(name, json), do: "@@@#{name}\n#{json}\n@@@\n"

  defp narrative(manifest, messages) do
    embed("manifest.json", Yoke.Json.encode!(manifest)) <>
      Enum.map_join(messages, "", fn {index, message} ->
        embed("message.#{index}.json", Yoke.Json.encode!(message))
      end)
  end

  test "new saves carry compact metadata that refreshes with the session", %{tmp_dir: cwd} do
    original = state()
    assert {:ok, path} = SessionStore.save_session(original, cwd)
    text = File.read!(path)
    {listing_pos, _} = :binary.match(text, "@@@listing.json")
    {manifest_pos, _} = :binary.match(text, "@@@manifest.json")
    assert listing_pos < manifest_pos

    assert %{title: "Find the bottleneck", message_count: 3, step_count: 7} =
             SessionStore.load_session_metadata("metadata", cwd)

    assert {:ok, %{"project" => project, "cwd" => saved_cwd}} = SessionMetadata.read(path)
    assert saved_cwd == Path.expand(cwd)
    assert project == Path.basename(Path.expand(cwd))

    updated = %{
      original
      | messages: original.messages ++ [%{"role" => "user", "content" => "Next"}]
    }

    assert {:ok, ^path} = SessionStore.save_session(updated, cwd)
    assert %{message_count: 4} = SessionStore.load_session_metadata("metadata", cwd)
    assert SessionStore.list_sessions(cwd) == ["metadata"]
    assert {:ok, _} = SessionStore.delete_session("metadata", cwd)
    assert SessionStore.list_session_metadata(cwd) == []
  end

  test "compact metadata does not require parsing or validating the history" do
    data = SessionMetadata.from_state(state(), "metadata", "2026-11-21T12:00:00")
    text = embed("listing.json", Yoke.Json.encode!(data)) <> "@@@manifest.json\nbroken"
    assert {:ok, ^data} = SessionMetadata.decode(text)
    refute Map.has_key?(data, "messages")
    refute Map.has_key?(data, "snapshots")
    refute Map.has_key?(data, "provider_options")
  end

  test "legacy messages are counted and titles are selected in numeric order" do
    callback = %{"role" => "user", "content" => "=== Async Background Job Finished (job) ==="}
    user = %{"role" => "user", "content" => "Actual request"}

    text =
      narrative(
        %{"session_id" => "legacy", "model" => "local"},
        [{10, %{"role" => "user", "content" => "Later"}}, {0, callback}, {2, user}]
      )

    assert {:ok, %{"message_count" => 3, "title" => "Actual request"}} =
             SessionMetadata.decode(text)
  end

  test "ignores embedded examples inside Markdown code fences and handles CRLF" do
    fake =
      embed("manifest.json", "{}") <>
        embed("message.0.json", ~s({"role":"user","content":"Fake"}))

    real = narrative(%{"session_id" => "real"}, [{0, %{"role" => "user", "content" => "Real"}}])
    text = "```lmml\n#{fake}```\n~~~lmml\n#{fake}~~~\n" <> real

    assert {:ok, %{"session_id" => "real", "message_count" => 1, "title" => "Real"}} =
             text |> String.replace("\n", "\r\n") |> SessionMetadata.decode()
  end

  @tag timeout: 10_000
  test "large legacy checkpoint manifests do not use the AST or regex fallback", %{tmp_dir: cwd} do
    dir = SessionStore.session_dir(cwd)
    File.mkdir_p!(dir)
    padding = String.duplicate("x", 20_000_000)
    json = ~s({"session_id":"large","model":"local","snapshots":[{"padding":"#{padding}"}]})

    text =
      embed("manifest.json", json) <>
        embed("message.0.json", ~s({"role":"user","content":"Large session title"}))

    File.write!(Path.join(dir, "large.lmml"), text)

    assert [%{session_id: "large", title: "Large session title", message_count: 1}] =
             SessionStore.list_session_metadata(cwd)
  end

  test "reads legacy zipped narratives without parsing or extracting attachments", %{tmp_dir: cwd} do
    name = "archive.lmml"

    text =
      narrative(%{"session_id" => "archive"}, [{0, %{"role" => "user", "content" => "Zip title"}}])

    dir = SessionStore.session_dir(cwd)
    File.mkdir_p!(dir)
    path = Path.join(dir, "archive.lmmlz")

    assert {:ok, _} =
             :zip.create(String.to_charlist(path), [
               {String.to_charlist(name), text},
               {~c"unused.png", <<1, 2, 3>>}
             ])

    assert %{title: "Zip title", message_count: 1} =
             SessionStore.load_session_metadata("archive", cwd)

    refute File.exists?(Path.join(cwd, "unused.png"))
  end

  test "legacy JSON and manifest-only sessions retain their title and counts", %{tmp_dir: cwd} do
    data = %{
      "session_id" => "legacy",
      "model" => "local",
      "messages" => [%{"role" => "user", "content" => "Legacy title"}]
    }

    dir = SessionStore.session_dir(cwd)
    File.mkdir_p!(dir)
    path = Path.join(dir, "legacy.json")
    File.write!(path, Yoke.Json.encode!(data))

    assert %{message_count: 1, title: "Legacy title"} =
             SessionStore.load_session_metadata("legacy", cwd)

    assert {:ok, %{"message_count" => 1, "title" => "Legacy title"}} =
             SessionMetadata.read(path)

    assert {:ok, %{"message_count" => 1, "title" => "Legacy title"}} =
             SessionMetadata.decode(narrative(data, []))
  end

  test "corrupt sessions remain visible and do not expose their contents in warnings", %{
    tmp_dir: cwd
  } do
    dir = SessionStore.session_dir(cwd)
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "corrupt.lmml"), "@@@manifest.json\nprivate malformed content")

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert [
                 %{
                   session_id: "corrupt",
                   title: "Unreadable session",
                   metadata_error: :unclosed_embed
                 }
               ] =
                 SessionStore.list_session_metadata(cwd)
      end)

    assert log =~ "Cannot read session metadata"
    refute log =~ "private malformed content"
  end

  test "invalid compact schemas fall back to legacy metadata" do
    text =
      embed("listing.json", ~s({"schema_version":99})) <>
        narrative(%{"session_id" => "legacy"}, [{0, %{"role" => "user", "content" => "Fallback"}}])

    assert {:ok, %{"title" => "Fallback"}} = SessionMetadata.decode(text)
  end

  test "invalid JSON message shapes are reported rather than crashing the listing", %{
    tmp_dir: cwd
  } do
    dir = SessionStore.session_dir(cwd)
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "invalid.json"), ~s({"messages":null}))

    ExUnit.CaptureLog.capture_log(fn ->
      assert [%{session_id: "invalid", metadata_error: :invalid_json_session}] =
               SessionStore.list_session_metadata(cwd)
    end)
  end

  test "preferred LMML metadata is used instead of a stale JSON fallback", %{tmp_dir: cwd} do
    assert {:ok, _} = SessionStore.save_session(state(), cwd)

    File.write!(
      Path.join(SessionStore.session_dir(cwd), "metadata.json"),
      Yoke.Json.encode!(%{"session_id" => "metadata", "messages" => []})
    )

    assert [%{session_id: "metadata", message_count: 3}] =
             SessionStore.list_session_metadata(cwd)
  end

  test "compact metadata validates field types before use", %{tmp_dir: cwd} do
    dir = SessionStore.session_dir(cwd)
    File.mkdir_p!(dir)
    bad = SessionMetadata.from_state(state(), "bad", "2026-11-21T12:00:00")
    text = embed("listing.json", Yoke.Json.encode!(Map.put(bad, "model", %{})))
    File.write!(Path.join(dir, "bad.lmml"), text)

    ExUnit.CaptureLog.capture_log(fn ->
      assert [%{session_id: "bad", metadata_error: :missing_manifest}] =
               SessionStore.list_session_metadata(cwd)
    end)
  end

  test "full session decoding remains lossless with the added listing embed" do
    original = state()
    assert {:ok, text} = SessionLmml.encode(original, original.session_id)
    assert {:ok, decoded} = SessionLmml.decode(text)
    assert decoded["messages"] == original.messages
  end
end
