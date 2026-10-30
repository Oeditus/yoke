defmodule Yoke.Brain.SessionStore do
  @moduledoc """
  Handles disk persistence for session memory, history checkpoints, and snapshots.
  Enables session resumption across CLI restarts.

  ## Storage markup

  Conversations are persisted in **`lmml`** -- a Markdown-superset markup
  language for LLM conversations (see `Lmml` and
  `Yoke.Brain.SessionLmml`) -- as a bare `.lmml` narrative file
  per session under `.yoke/sessions/<session_id>.lmml`. This is the default
  markup for stored conversations: human-readable Markdown that any Markdown
  viewer renders sensibly, yet losslessly round-trips every structured
  message (metadata, snapshots, tool calls, multimodal content) through its
  inline-embed model.

  Legacy `.json` session files written by earlier versions are still read
  transparently on `load_session/2` / `load_session_metadata/2`, so existing
  conversations remain resumable; new saves always write `.lmml`.
  """
  require Logger

  alias Yoke.Brain.SessionLmml

  @doc "Saves session state and snapshots to disk as an `.lmml` narrative or `.lmmlz` zipped container."
  def save_session(session_state, cwd \\ ".") do
    session_state = sanitize_session_state(session_state)
    session_id = session_state.session_id
    dir = session_dir(cwd)
    images = Map.get(session_state, :images) || Map.get(session_state, "images") || %{}

    if is_map(images) and map_size(images) > 0 do
      lmmlz_path = Path.join(dir, "#{session_id}.lmmlz")
      lmml_path = Path.join(dir, "#{session_id}.lmml")

      with :ok <- File.mkdir_p(dir),
           {:ok, narrative} <- SessionLmml.encode(session_state, session_id),
           {:ok, bundle} <- Lmml.Bundle.new_zip("#{session_id}.lmml", narrative, images),
           :ok <- Lmml.Bundle.write!(bundle, lmmlz_path) do
        if File.exists?(lmml_path), do: File.rm(lmml_path)
        {:ok, lmmlz_path}
      else
        err ->
          Logger.error(
            "[SessionStore] Failed to save zipped session '#{session_id}': #{format_error(err)}"
          )

          fallback_save(session_state, dir, session_id, err)
      end
    else
      file_path = Path.join(dir, "#{session_id}.lmml")

      with :ok <- File.mkdir_p(dir),
           {:ok, narrative} <- SessionLmml.encode(session_state, session_id),
           :ok <- File.write(file_path, narrative) do
        {:ok, file_path}
      else
        err ->
          Logger.error(
            "[SessionStore] Failed to save session '#{session_id}': #{format_error(err)}"
          )

          fallback_save(session_state, dir, session_id, err)
      end
    end
  end

  defp format_error(%_struct{} = exception) when is_exception(exception) do
    Exception.format(:error, exception)
  end

  defp format_error(err) do
    inspect(err, pretty: true, limit: :infinity)
  end

  defp sanitize_session_state(session_state) when is_map(session_state) do
    images = Map.get(session_state, :images) || Map.get(session_state, "images")

    clean_state =
      session_state
      |> Map.delete(:images)
      |> Map.delete("images")
      |> Yoke.Json.sanitize_utf8()

    cond do
      Map.has_key?(session_state, :images) -> Map.put(clean_state, :images, images)
      Map.has_key?(session_state, "images") -> Map.put(clean_state, "images", images)
      true -> clean_state
    end
  end

  defp sanitize_session_state(other), do: other

  @doc false
  def fallback_save(session_state, dir, session_id, primary_error) do
    session_state = sanitize_session_state(session_state)
    json_path = Path.join(dir, "#{session_id}.json")

    case Yoke.Json.encode(session_state, pretty: true) do
      {:ok, json_data} ->
        case File.write(json_path, json_data) do
          :ok ->
            Logger.info(
              "[SessionStore] Successfully saved session '#{session_id}' to JSON fallback path '#{json_path}'."
            )

            write_lmml_error_log(
              session_state,
              dir,
              session_id,
              primary_error,
              "SUCCESS (JSON Fallback Saved)",
              json_path
            )

            {:ok, json_path}

          write_err ->
            Logger.error(
              "[SessionStore] Critical: JSON fallback write failed for session '#{session_id}': #{format_error(write_err)}"
            )

            write_lmml_error_log(
              session_state,
              dir,
              session_id,
              primary_error,
              "FAILED (JSON Write Error)",
              format_error(write_err)
            )

            {:error, primary_error}
        end

      encode_err ->
        Logger.error(
          "[SessionStore] Critical: JSON encoding failed for session '#{session_id}': #{format_error(encode_err)}"
        )

        write_lmml_error_log(
          session_state,
          dir,
          session_id,
          primary_error,
          "FAILED (JSON Encode Error)",
          format_error(encode_err)
        )

        {:error, primary_error}
    end
  rescue
    e ->
      stacktrace = Exception.format(:error, e, __STACKTRACE__)

      Logger.error(
        "[SessionStore] Fallback save exception for session '#{session_id}': #{stacktrace}"
      )

      write_lmml_error_log(
        session_state,
        dir,
        session_id,
        primary_error,
        "FAILED (Fallback Exception)",
        stacktrace
      )

      {:error, primary_error}
  end

  defp write_lmml_error_log(
         session_state,
         dir,
         session_id,
         primary_error,
         fallback_status,
         fallback_detail
       ) do
    log_path = Path.join(dir, "#{session_id}.lmml_error.log")
    timestamp = DateTime.utc_now() |> DateTime.to_iso8601()
    model = Map.get(session_state, :model) || Map.get(session_state, "model") || "unknown"
    messages = Map.get(session_state, :messages) || Map.get(session_state, "messages") || []
    snapshots = Map.get(session_state, :snapshots) || Map.get(session_state, "snapshots") || []

    step_count =
      Map.get(session_state, :step_count) || Map.get(session_state, "step_count") || 0

    log_content = """
    ================================================================================
    Yoke LMML Persistence Error Report
    ================================================================================
    Timestamp:        #{timestamp}
    Session ID:       #{session_id}
    Model:            #{model}
    Target Directory: #{dir}
    ================================================================================

    === PRIMARY LMML ENCODING / WRITE FAILURE ===
    #{format_error(primary_error)}

    === FALLBACK PERSISTENCE ACTION ===
    Status: #{fallback_status}
    Detail: #{fallback_detail}

    === SESSION METADATA AT FAILURE ===
    Message Count:   #{length(messages)}
    Snapshots Count: #{length(snapshots)}
    Step Count:      #{step_count}

    ================================================================================
    """

    case File.write(log_path, log_content) do
      :ok ->
        Logger.info("[SessionStore] Detailed LMML error report written to '#{log_path}'.")

      err ->
        Logger.error(
          "[SessionStore] Failed to write LMML error log to '#{log_path}': #{format_error(err)}"
        )
    end
  rescue
    e ->
      Logger.error(
        "[SessionStore] Exception writing LMML error log: #{Exception.format(:error, e, __STACKTRACE__)}"
      )
  end

  @doc "Appends a full untruncated step log to local transcript files (.yoke/sessions/<id>/transcript_full.jsonl and transcript_compact.jsonl)."
  def append_transcript(session_id, step_type, payload, cwd \\ ".") do
    dir = Path.join(session_dir(cwd), session_id)
    File.mkdir_p!(dir)

    entry = %{
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "type" => to_string(step_type),
      "payload" => payload
    }

    full_path = Path.join(dir, "transcript_full.jsonl")
    line = Yoke.Json.encode!(entry) <> "\n"
    File.write!(full_path, line, [:append])

    compact_path = Path.join(dir, "transcript_compact.jsonl")
    compact_line = Yoke.Json.encode!(%{entry | "payload" => compact_payload(payload)}) <> "\n"
    File.write!(compact_path, compact_line, [:append])
  rescue
    _ -> :ok
  end

  defp compact_payload(payload) when is_binary(payload) do
    if byte_size(payload) > 500 do
      String.slice(payload, 0, 500) <> "... [truncated]"
    else
      payload
    end
  end

  defp compact_payload(map) when is_map(map) do
    Enum.into(map, %{}, fn {k, v} -> {k, compact_payload(v)} end)
  end

  defp compact_payload(list) when is_list(list) do
    Enum.map(list, &compact_payload/1)
  end

  defp compact_payload(val), do: val

  @doc """
  Loads a persisted session from disk.

  Prefers the `.lmmlz` zipped-container narrative (if images were stored),
  then bare `.lmml` narrative; if no `.lmml` file exists but a legacy
  `<session_id>.json` does, it is read and returned.
  """
  def load_session(session_id, cwd \\ ".") do
    lmmlz_path = Path.join(session_dir(cwd), "#{session_id}.lmmlz")
    lmml_path = Path.join(session_dir(cwd), "#{session_id}.lmml")
    json_path = Path.join(session_dir(cwd), "#{session_id}.json")

    cond do
      File.exists?(lmmlz_path) ->
        load_lmmlz_session(lmmlz_path)

      File.exists?(lmml_path) ->
        load_lmml_session(lmml_path)

      File.exists?(json_path) ->
        load_legacy_json(json_path)

      true ->
        {:error, "Session file for '#{session_id}' does not exist in #{session_dir(cwd)}."}
    end
  end

  defp load_lmmlz_session(lmmlz_path) do
    case Lmml.open(lmmlz_path) do
      {:ok, %Lmml.Bundle{} = bundle} ->
        case SessionLmml.decode(bundle) do
          {:ok, data} ->
            entries = Map.new(bundle.entries, fn {k, v} -> {k, v} end)
            {:ok, Map.put(data, "images", entries)}

          err ->
            {:error, "Failed to decode zipped session file '#{lmmlz_path}': #{inspect(err)}"}
        end

      err ->
        {:error, "Failed to open zipped session file '#{lmmlz_path}': #{inspect(err)}"}
    end
  end

  defp load_lmml_session(lmml_path) do
    case File.read(lmml_path) do
      {:ok, content} -> SessionLmml.decode(content)
      err -> {:error, "Failed to read session file '#{lmml_path}': #{inspect(err)}"}
    end
  end

  defp load_legacy_json(json_path) do
    with {:ok, content} <- File.read(json_path),
         {:ok, data} when is_map(data) <- Yoke.Json.decode(content) do
      {:ok, data}
    else
      err -> {:error, "Failed to decode legacy session file '#{json_path}': #{inspect(err)}"}
    end
  end

  @doc """
  Imports an externally-produced session file into Yoke's own on-disk
  session store, so it can be resumed like any native session via `/resume`
  or `/session switch`. Replaces ad-hoc external scripts previously used to
  massage foreign session exports into a loadable shape.

  Tolerantly accepts several shapes at `source_path`:
    - the native `save_session/2` schema (`session_id`, `model`,
      `permission_mode`, `step_count`, `total_prompt_tokens`,
      `total_completion_tokens`, `messages`, `snapshots`)
    - the `/export json` schema (`session_id`, `model`, `exported_at`,
      `total_tokens`, `messages`)
    - a bare `%{"messages" => [...]}` object
    - a raw top-level JSON array of message objects
    - a `.lmml` narrative (imported directly, metadata + messages intact)

  `opts` supports:
    - `:session_id` -- target session ID (defaults to the source file's own
      `"session_id"` field, or a freshly generated UUID)
    - `:overwrite` -- when `true`, allows replacing an existing session file
      with the same ID (default: `false`)

  Returns `{:ok, session_id, file_path}` or `{:error, reason}`.
  """
  def import_session(source_path, opts \\ [], cwd \\ ".") do
    with {:ok, content} <- read_import_file(source_path),
         {:ok, messages, meta} <- parse_import_content(content, source_path) do
      session_id = opts[:session_id] || meta["session_id"] || generate_session_id()
      file_path = Path.join(session_dir(cwd), "#{session_id}.lmml")

      if File.exists?(file_path) and !Keyword.get(opts, :overwrite, false) do
        {:error,
         "Session '#{session_id}' already exists at #{file_path}. Pass a different session_id, or overwrite: true."}
      else
        session_state = %{
          session_id: session_id,
          model: meta["model"] || "deepseek-flash",
          permission_mode: normalize_permission_mode(meta["permission_mode"]),
          step_count: meta["step_count"] || 0,
          total_prompt_tokens: meta["total_prompt_tokens"] || 0,
          total_completion_tokens: meta["total_completion_tokens"] || 0,
          messages: messages,
          snapshots: meta["snapshots"] || []
        }

        case save_session(session_state, cwd) do
          {:ok, path} -> {:ok, session_id, path}
          {:error, reason} -> {:error, "Failed to write imported session: #{inspect(reason)}"}
        end
      end
    end
  end

  defp read_import_file(source_path) do
    case File.read(source_path) do
      {:ok, content} -> {:ok, content}
      {:error, reason} -> {:error, "Failed to read '#{source_path}': #{inspect(reason)}"}
    end
  end

  # An `.lmml` narrative (sniffed by its content) is parsed through
  # `SessionLmml` so its metadata and messages are imported intact.
  defp parse_import_content(content, source_path) do
    if lmml_narrative?(content) do
      case SessionLmml.decode(content) do
        {:ok, data} ->
          {:ok, data["messages"], data}

        {:error, reason} ->
          {:error, "Invalid lmml narrative in '#{source_path}': #{inspect(reason)}"}
      end
    else
      parse_import_json(content, source_path)
    end
  end

  defp lmml_narrative?(content) when is_binary(content) do
    # A bare `.lmml` text narrative (not a zip archive) is our storage form.
    # Detect it by the presence of `@@@` inline-embed fences -- the one
    # syntactic construct native JSON session files never contain. This
    # covers both Yoke-produced narratives (which carry a `@@@manifest.json`
    # embed) and generic `.lmml` conversations built with `Lmml.Bundle`.
    String.contains?(content, "@@@")
  end

  defp parse_import_json(content, source_path) do
    case Yoke.Json.decode(content) do
      {:ok, data} when is_list(data) ->
        {:ok, data, %{}}

      {:ok, %{"messages" => msgs} = data} when is_list(msgs) ->
        {:ok, msgs, data}

      {:ok, data} when is_map(data) ->
        {:error,
         "Source JSON must be either a top-level array of messages, or an object with a 'messages' array."}

      {:ok, _other} ->
        {:error,
         "Source JSON must be either a top-level array of messages, or an object with a 'messages' array."}

      {:error, err} ->
        {:error, "Invalid JSON in '#{source_path}': #{inspect(err)}"}
    end
  end

  defp normalize_permission_mode(mode) when mode in ["auto_approve", "ask_confirm"], do: mode
  defp normalize_permission_mode(_), do: "ask_confirm"

  defp generate_session_id do
    <<a::32, b::16, c::16, d::16, e::48>> = :crypto.strong_rand_bytes(16)

    :io_lib.format("~8.16.0b-~4.16.0b-~4.16.0b-~4.16.0b-~12.16.0b", [a, b, c, d, e])
    |> IO.iodata_to_binary()
  end

  @doc "Lists all saved session IDs (`.lmmlz`, `.lmml`, and legacy `.json`)."
  def list_sessions(cwd \\ ".") do
    dir = session_dir(cwd)

    if File.dir?(dir) do
      case File.ls(dir) do
        {:ok, files} ->
          files
          |> Enum.filter(fn f ->
            String.ends_with?(f, ".lmmlz") or String.ends_with?(f, ".lmml") or
              String.ends_with?(f, ".json")
          end)
          |> Enum.map(&session_id_from_filename/1)
          |> Enum.uniq()

        _ ->
          []
      end
    else
      []
    end
  end

  @doc "Returns the total number of distinct saved sessions in workspace."
  def count_sessions(cwd \\ ".") do
    dir = session_dir(cwd)

    if File.dir?(dir) do
      case File.ls(dir) do
        {:ok, files} ->
          files
          |> Enum.filter(fn f ->
            String.ends_with?(f, ".lmmlz") or String.ends_with?(f, ".lmml") or
              String.ends_with?(f, ".json")
          end)
          |> Enum.map(&session_id_from_filename/1)
          |> Enum.uniq()
          |> length()

        _ ->
          0
      end
    else
      0
    end
  end

  defp session_id_from_filename(f) do
    f
    |> String.replace_suffix(".lmmlz", "")
    |> String.replace_suffix(".lmml", "")
    |> String.replace_suffix(".json", "")
  end

  @doc """
  Deletes a persisted session state file from disk.

  Removes both `.lmmlz` / `.lmml` narrative and any legacy `.json` file for the
  session. Returns `{:ok, path}` on success, or `{:error, reason}` when no
  session file exists or a removal fails.
  """
  def delete_session(session_id, cwd \\ ".") do
    dir = session_dir(cwd)
    lmmlz_path = Path.join(dir, "#{session_id}.lmmlz")
    lmml_path = Path.join(dir, "#{session_id}.lmml")
    json_path = Path.join(dir, "#{session_id}.json")

    rm_lmmlz = File.rm(lmmlz_path)
    rm_lmml = File.rm(lmml_path)
    rm_json = File.rm(json_path)

    cond do
      rm_lmmlz == :ok -> {:ok, lmmlz_path}
      rm_lmml == :ok -> {:ok, lmml_path}
      rm_json == :ok -> {:ok, json_path}
      true -> {:error, "Session '#{session_id}' has no persisted state to delete."}
    end
  end

  @doc """
  Returns metadata about persisted sessions in the workspace.

  Options:
    * `:limit` - maximum number of sessions to return (integer or `:all`; default `:all`)
    * `:offset` - number of sessions to skip (integer; default `0`)

  Candidate session files are first sorted by filesystem modification time (`mtime`)
  so only the requested page of session files needs to be read and decoded.
  """
  def list_session_metadata(cwd_or_opts \\ ".", opts \\ []) do
    {cwd, opts} =
      if is_list(cwd_or_opts) do
        {Keyword.get(cwd_or_opts, :cwd, "."), cwd_or_opts}
      else
        {cwd_or_opts, opts}
      end

    limit = Keyword.get(opts, :limit, :all)
    offset = Keyword.get(opts, :offset, 0)
    dir = session_dir(cwd)

    if File.dir?(dir) do
      case File.ls(dir) do
        {:ok, files} ->
          candidates =
            files
            |> Enum.filter(fn f ->
              String.ends_with?(f, ".lmmlz") or String.ends_with?(f, ".lmml") or
                String.ends_with?(f, ".json")
            end)
            |> Enum.group_by(&session_id_from_filename/1)
            |> Enum.map(fn {_id, flist} ->
              best =
                Enum.find(flist, &String.ends_with?(&1, ".lmmlz")) ||
                  Enum.find(flist, &String.ends_with?(&1, ".lmml")) ||
                  hd(flist)

              Path.join(dir, best)
            end)

          candidates_with_mtime =
            candidates
            |> Enum.map(fn path ->
              mtime =
                case File.stat(path) do
                  {:ok, %{mtime: mt}} -> mt
                  _ -> {{1970, 1, 1}, {0, 0, 0}}
                end

              {path, mtime}
            end)
            |> Enum.sort_by(fn {_path, mtime} -> mtime end, :desc)

          candidates_to_read =
            candidates_with_mtime
            |> Enum.drop(offset)
            |> maybe_take(limit)

          candidates_to_read
          |> Enum.map(fn {path, _} -> read_session_metadata(path) end)
          |> Enum.reject(&is_nil/1)
          |> Enum.sort_by(& &1[:updated_at], {:desc, NaiveDateTime})

        _ ->
          []
      end
    else
      []
    end
  end

  defp maybe_take(list, :all), do: list
  defp maybe_take(list, limit) when is_integer(limit) and limit >= 0, do: Enum.take(list, limit)
  defp maybe_take(list, _), do: list

  @doc """
  Loads only the persisted session metadata (without the full message
  history) for a given session id, or `nil` when no such session exists.
  """
  def load_session_metadata(session_id, cwd \\ ".") do
    dir = session_dir(cwd)
    lmmlz_path = Path.join(dir, "#{session_id}.lmmlz")
    lmml_path = Path.join(dir, "#{session_id}.lmml")
    json_path = Path.join(dir, "#{session_id}.json")

    cond do
      File.exists?(lmmlz_path) -> read_session_metadata(lmmlz_path)
      File.exists?(lmml_path) -> read_session_metadata(lmml_path)
      File.exists?(json_path) -> read_session_metadata(json_path)
      true -> nil
    end
  end

  defp read_session_metadata(file_path) do
    if String.ends_with?(file_path, ".lmmlz") do
      case Lmml.Bundle.open(file_path) do
        {:ok, bundle} ->
          case SessionLmml.decode(bundle) do
            {:ok, data} -> build_metadata(data)
            _ -> nil
          end

        _ ->
          nil
      end
    else
      case File.read(file_path) do
        {:ok, content} -> parse_metadata_content(file_path, content)
        _ -> nil
      end
    end
  end

  defp parse_metadata_content(file_path, content) do
    if String.ends_with?(file_path, ".lmml") do
      case SessionLmml.decode(content) do
        {:ok, data} -> build_metadata(data)
        _ -> nil
      end
    else
      case Yoke.Json.decode(content) do
        {:ok, map} when is_map(map) -> build_metadata(map)
        _ -> nil
      end
    end
  end

  defp build_metadata(map) do
    messages = Map.get(map, "messages", [])
    updated_at = parse_timestamp(map["updated_at"])

    title =
      case map["title"] do
        t when is_binary(t) and byte_size(t) > 0 ->
          cleaned = clean_prompt_text(t)

          if cleaned != "" and not String.starts_with?(cleaned, "==="),
            do: sanitize_title(cleaned),
            else: extract_first_user_message(messages)

        _ ->
          extract_first_user_message(messages)
      end

    %{
      session_id: map["session_id"],
      model: map["model"],
      updated_at: updated_at,
      message_count: length(messages),
      step_count: Map.get(map, "step_count", 0),
      title: title
    }
  end

  @doc "Extracts and truncates the first user message content from session history, stripping preambles and instructions."
  def extract_first_user_message(messages) when is_list(messages) do
    user_msgs =
      Enum.filter(messages, fn
        %{"role" => "user"} = msg -> get_msg_raw_text(msg) != ""
        %{role: "user"} = msg -> get_msg_raw_text(msg) != ""
        _ -> false
      end)

    selected_msg =
      Enum.find(user_msgs, fn msg ->
        text = get_msg_raw_text(msg)
        not internal_callback?(text)
      end) || List.first(user_msgs)

    case selected_msg do
      nil ->
        nil

      msg ->
        cleaned =
          msg
          |> get_msg_raw_text()
          |> clean_prompt_text()

        title_text =
          if cleaned != "" do
            cleaned
          else
            get_msg_raw_text(msg)
          end

        sanitize_title(title_text)
    end
  end

  def extract_first_user_message(_), do: nil

  defp get_msg_raw_text(%{"content" => content}), do: get_message_text(content)
  defp get_msg_raw_text(%{content: content}), do: get_message_text(content)
  defp get_msg_raw_text(_), do: ""

  defp internal_callback?(text) when is_binary(text) do
    trimmed = String.trim_leading(text)

    String.starts_with?(trimmed, "=== Async Background Job Finished") or
      String.starts_with?(trimmed, "=== Async Subagent Result") or
      String.starts_with?(trimmed, "=== Async Subagent Failure")
  end

  @doc "Strips system-injected preambles, execution rules, language practices, lessons learned, and skill wrappers."
  def clean_prompt_text(text) when is_binary(text) do
    text
    |> strip_leading_preambles()
    |> simplify_skill_prompt()
    |> String.trim()
  end

  def clean_prompt_text(other), do: get_message_text(other)

  defp strip_leading_preambles(text) do
    Stream.iterate(text, fn current ->
      trimmed = String.trim_leading(current)

      cond do
        # 1. Block bounded by === ... === and closed by ===+
        Regex.match?(~r/^===[^\n]+===.*?\n={3,}\s*/s, trimmed) ->
          Regex.replace(~r/^===[^\n]+===.*?\n={3,}\s*/s, trimmed, "")

        # 2. Lessons learned block: "### Project Lessons Learned & Gotchas ..."
        Regex.match?(
          ~r/^###\s+(?:Project\s+)?Lessons Learned.*?(?=(?:\n\n(?!\s*[-*#>\d]))|\n={3,}|\z)/s,
          trimmed
        ) ->
          Regex.replace(
            ~r/^###\s+(?:Project\s+)?Lessons Learned.*?(?=(?:\n\n(?!\s*[-*#>\d]))|\n={3,}|\z)/s,
            trimmed,
            ""
          )

        # 3. Leading async callback header: "=== Async Subagent Result (...) ==="
        Regex.match?(~r/^===\s*Async[^\n]+===\s*/s, trimmed) ->
          Regex.replace(~r/^===\s*Async[^\n]+===\s*/s, trimmed, "")

        # 4. Leading "=== System Instructions ===" or "=== Context ===" without a closing ===+ line:
        Regex.match?(~r/^===[^\n]*(?:Instructions|Context|Rules|Skills)[^\n]*===\s*/si, trimmed) ->
          Regex.replace(
            ~r/^===[^\n]*(?:Instructions|Context|Rules|Skills)[^\n]*===\s*/si,
            trimmed,
            ""
          )

        true ->
          trimmed
      end
    end)
    |> Stream.chunk_every(2, 1)
    |> Enum.find_value(fn [prev, curr] -> if prev == curr, do: curr end)
  end

  defp simplify_skill_prompt(text) do
    case Regex.run(
           ~r/^Execute skill\s+['"]([^'"]+)['"](?:\s+with arguments\s+['"]([^'"]*)['"])?:/s,
           text
         ) do
      [_, name, ""] -> "/skills #{name}"
      [_, name, args] -> "/skills #{name} #{args}"
      [_, name] -> "/skills #{name}"
      _ -> text
    end
  end

  defp get_message_text(content) when is_binary(content), do: content

  defp get_message_text(content) when is_list(content) do
    Enum.map_join(content, " ", fn
      %{"text" => text} when is_binary(text) -> text
      %{text: text} when is_binary(text) -> text
      _ -> ""
    end)
  end

  defp get_message_text(_), do: ""

  # `get_message_text/1` (the only caller) always returns a binary, so this
  # single clause covers every real input; dialyzer confirms a catch-all
  # fallback clause here would be unreachable dead code.
  defp sanitize_title(text) when is_binary(text) do
    cleaned =
      text
      |> String.replace(~r/[\r\n\t]+/, " ")
      |> String.replace(~r/\s+/, " ")
      |> String.trim()
      |> String.trim("\"")
      |> String.trim()

    if cleaned == "" do
      nil
    else
      truncate_text(cleaned, 60)
    end
  end

  defp truncate_text(text, max_len) do
    if String.length(text) > max_len do
      String.slice(text, 0, max_len - 3) <> "..."
    else
      text
    end
  end

  defp parse_timestamp(nil), do: NaiveDateTime.utc_now()

  defp parse_timestamp(iso) when is_binary(iso) do
    case NaiveDateTime.from_iso8601(iso) do
      {:ok, dt} -> dt
      _ -> NaiveDateTime.utc_now()
    end
  end

  defp parse_timestamp(_), do: NaiveDateTime.utc_now()

  def session_dir(cwd \\ ".") do
    Path.join(cwd, ".yoke/sessions")
  end
end
