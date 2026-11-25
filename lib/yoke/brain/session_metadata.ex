defmodule Yoke.Brain.SessionMetadata do
  @moduledoc """
  Reads listing metadata without constructing an LMML AST or restoring history.

  New sessions carry a small versioned `listing.json` embed before their manifest.
  Older narratives are scanned once for top-level embeds, skipping Markdown code
  fences and retaining only the manifest and message locations needed for listing.
  This reader is not a substitute for full session validation on resume.
  """

  alias Yoke.Brain.SessionStore

  @doc "Builds a compact, credential-free listing record from live session state."
  def from_state(state, session_id, updated_at) do
    messages = Map.get(state, :messages, [])

    base = %{
      "schema_version" => 1,
      "session_id" => session_id,
      "model" => Map.get(state, :model, "deepseek-flash"),
      "updated_at" => updated_at,
      "step_count" => Map.get(state, :step_count, 0),
      "message_count" => length(messages),
      "title" => SessionStore.extract_first_user_message(messages)
    }

    maybe_put_project(base, state)
  end

  defp maybe_put_project(record, state) do
    cwd = Map.get(state, :cwd) || Map.get(state, "cwd")
    explicit_project = Map.get(state, :project) || Map.get(state, "project")

    record =
      if is_binary(cwd) and cwd != "" do
        expanded = Path.expand(cwd)
        project = explicit_project || project_name_for_cwd(expanded)

        record
        |> Map.put("cwd", expanded)
        |> Map.put("project", project)
      else
        if is_binary(explicit_project) and explicit_project != "" do
          Map.put(record, "project", explicit_project)
        else
          record
        end
      end

    record
  end

  @doc "Derives a human-readable project label from a working directory path."
  def project_name_for_cwd(cwd) when is_binary(cwd) do
    expanded = Path.expand(cwd)
    home = Path.expand("~")

    cond do
      expanded == home -> "global"
      expanded == "/" -> "/"
      true -> Path.basename(expanded)
    end
  end

  def project_name_for_cwd(_), do: "unknown"

  @doc "Reads an LMML, LMMLZ, or legacy JSON session without restoring it."
  def read(path) do
    result =
      case Path.extname(path) do
        ".lmmlz" -> read_zip(path)
        ".lmml" -> with {:ok, text} <- File.read(path), do: decode(text)
        ".json" -> read_json(path)
        _ -> {:error, :unsupported_session_format}
      end

    with {:ok, data} <- result do
      validate_metadata(data)
    end
  end

  defp read_json(path) do
    with {:ok, text} <- File.read(path),
         {:ok, data} when is_map(data) <- Yoke.Json.decode(text),
         messages when is_list(messages) <- Map.get(data, "messages", []) do
      {:ok,
       data
       |> Map.take(["session_id", "model", "updated_at", "step_count", "title"])
       |> Map.put("message_count", length(messages))
       |> Map.put("title", data["title"] || SessionStore.extract_first_user_message(messages))}
    else
      _ -> {:error, :invalid_json_session}
    end
  end

  # Extract only the canonical narrative, never image assets or entries to disk.
  defp read_zip(path) do
    name = path |> Path.basename() |> String.trim_trailing("z") |> String.to_charlist()

    case :zip.extract(String.to_charlist(path), [:memory, {:file_list, [name]}]) do
      {:ok, [{^name, text}]} -> decode(text)
      _ -> {:error, :invalid_zip_narrative}
    end
  end

  defp validate_metadata(data) do
    count = Map.get(data, "message_count", length(Map.get(data, "messages", [])))
    model = Map.get(data, "model") || "unknown"
    steps = Map.get(data, "step_count") || 0
    title = Map.get(data, "title")

    if is_integer(count) and count >= 0 and is_binary(model) and
         is_integer(steps) and steps >= 0 and (is_nil(title) or is_binary(title)) do
      {:ok,
       data
       |> Map.put("model", model)
       |> Map.put("step_count", steps)
       |> Map.put("message_count", count)}
    else
      {:error, :invalid_listing_metadata}
    end
  end

  @doc "Extracts listing metadata using a linear scan of narrative fences."
  def decode(text) when is_binary(text) do
    scan(text, %{manifest: nil, messages: [], code: nil})
  end

  defp scan("", state), do: legacy_metadata(state)

  defp scan(text, state) do
    {line, rest} = take_line(text)
    trimmed = String.trim(line)
    fence = code_fence(trimmed)

    cond do
      state.code != nil ->
        code = if closes_code?(trimmed, state.code), do: nil, else: state.code
        scan(rest, %{state | code: code})

      fence != nil ->
        scan(rest, %{state | code: fence})

      String.starts_with?(line, "@@@") ->
        name = line |> String.trim_leading("@@@") |> String.trim()

        with {:ok, body, tail} <- take_embed(rest) do
          consume_embed(name, body, tail, state)
        end

      true ->
        scan(rest, state)
    end
  end

  defp consume_embed("listing.json", body, rest, state) do
    case Yoke.Json.decode(body) do
      {:ok,
       %{
         "schema_version" => 1,
         "message_count" => count,
         "session_id" => id,
         "model" => model,
         "step_count" => steps,
         "updated_at" => updated_at,
         "title" => title
       } = data}
      when is_integer(count) and count >= 0 and is_binary(id) and id != "" and
             is_binary(model) and is_integer(steps) and steps >= 0 and
             is_binary(updated_at) and (is_binary(title) or is_nil(title)) ->
        {:ok,
         Map.take(data, [
           "schema_version",
           "message_count",
           "session_id",
           "model",
           "step_count",
           "updated_at",
           "title",
           "project",
           "cwd"
         ])}

      _ ->
        scan(rest, state)
    end
  end

  defp consume_embed("manifest.json", body, rest, state) do
    scan(rest, %{state | manifest: body})
  end

  defp consume_embed("message." <> suffix, body, rest, state) do
    case Integer.parse(suffix) do
      {index, ".json"} when index >= 0 ->
        scan(rest, %{state | messages: [{index, body} | state.messages]})

      _ ->
        scan(rest, state)
    end
  end

  defp consume_embed(_name, _body, rest, state), do: scan(rest, state)

  defp legacy_metadata(%{manifest: nil}), do: {:error, :missing_manifest}

  defp legacy_metadata(%{manifest: json, messages: messages}) do
    case Yoke.Json.decode(json) do
      {:ok, manifest} when is_map(manifest) ->
        legacy_listing(manifest, messages)

      _ ->
        {:error, :invalid_manifest}
    end
  end

  defp legacy_listing(manifest, []) do
    case Map.get(manifest, "messages", []) do
      messages when is_list(messages) ->
        {:ok,
         manifest
         |> Map.take(["session_id", "model", "updated_at", "step_count", "title"])
         |> Map.put("message_count", length(messages))
         |> Map.put(
           "title",
           manifest["title"] || SessionStore.extract_first_user_message(messages)
         )}

      _ ->
        {:error, :invalid_messages}
    end
  end

  defp legacy_listing(manifest, messages) do
    title =
      messages
      |> Enum.sort_by(&elem(&1, 0))
      |> first_user_title(nil)

    {:ok,
     manifest
     |> Map.take(["session_id", "model", "updated_at", "step_count"])
     |> Map.put("message_count", length(messages))
     |> Map.put("title", manifest["title"] || title)}
  end

  defp first_user_title([], fallback), do: fallback

  defp first_user_title([{_index, json} | rest], fallback) do
    case Yoke.Json.decode(json) do
      {:ok, %{"role" => "user"} = message} ->
        title = SessionStore.extract_first_user_message([message])
        raw = message_text(message["content"]) |> String.trim_leading()

        if title == nil or
             String.starts_with?(raw, [
               "=== Async Background Job Finished",
               "=== Async Subagent Result",
               "=== Async Subagent Failure"
             ]) do
          first_user_title(rest, fallback || title)
        else
          title
        end

      _ ->
        first_user_title(rest, fallback)
    end
  end

  defp message_text(text) when is_binary(text), do: text

  defp message_text(parts) when is_list(parts) do
    Enum.map_join(parts, " ", fn
      %{"text" => text} when is_binary(text) -> text
      _ -> ""
    end)
  end

  defp message_text(_), do: ""

  defp take_line(text) do
    case :binary.match(text, "\n") do
      {offset, 1} ->
        {binary_part(text, 0, offset) |> String.trim_trailing("\r"),
         binary_part(text, offset + 1, byte_size(text) - offset - 1)}

      :nomatch ->
        {String.trim_trailing(text, "\r"), ""}
    end
  end

  defp take_embed(text) do
    {line, rest} = take_line(text)

    if String.trim(line) == "@@@" do
      {:ok, "", rest}
    else
      find_embed_end(text, text, 0)
    end
  end

  defp find_embed_end(original, remaining, consumed) do
    case :binary.match(remaining, "\n@@@") do
      {offset, 4} ->
        after_newline = binary_part(remaining, offset + 1, byte_size(remaining) - offset - 1)
        {line, rest} = take_line(after_newline)

        if String.trim(line) == "@@@" do
          {:ok, binary_part(original, 0, consumed + offset), rest}
        else
          next = offset + 4
          tail = binary_part(remaining, next, byte_size(remaining) - next)
          find_embed_end(original, tail, consumed + next)
        end

      :nomatch ->
        {:error, :unclosed_embed}
    end
  end

  defp code_fence(<<char, char, char, _::binary>> = line) when char in [?`, ?~] do
    {char, leading_run(line, char, 0)}
  end

  defp code_fence(_), do: nil

  defp closes_code?(line, {char, count}) do
    leading_run(line, char, 0) >= count and
      String.trim_leading(line, <<char>>) == ""
  end

  defp leading_run(<<char, rest::binary>>, char, count), do: leading_run(rest, char, count + 1)
  defp leading_run(_rest, _char, count), do: count
end
