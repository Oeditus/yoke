defmodule Yoke.Brain.SessionLmml do
  @moduledoc """
  Serializes Yoke session state to and from the `lmml` markup format
  (a Markdown-superset language for structuring LLM conversations -- see
  `Lmml`), making `lmml` the default on-disk markup for stored
  conversations.

  A session is encoded as a *narrative* (the human-readable, ordered view
  of the conversation) plus two kinds of named *embeds*:

    - `@@@manifest.json ... @@@` -- the session's metadata and temporal
      snapshots, `Lmml.Manifest`-compatible.
    - `@@@message.N.json ... @@@` -- one inline embed per message, carrying
      the exact JSON of that message so a save/load round-trip is lossless
      even for structured messages (tool calls, tool results, multimodal
      `content` arrays, reasoning text).

  The narrative prose is deliberately a *view*, not the source of truth:
  reading the file as a human gives you the whole conversation at a glance,
  while `decode/1` reconstructs the authoritative `messages` list from the
  embeds. This mirrors `lmml`'s own model of "an ordered narrative with
  zero or more named embeds."

  ## Why `.lmml` and not `.json`

  A `.lmml` narrative is plain, self-contained, git-diff-friendly Markdown
  that any Markdown viewer renders sensibly, yet every structured detail
  (metadata, snapshots, tool calls, images) round-trips losslessly through
  its embed model -- see `Lmml.Bundle`, `Lmml.Manifest` and
  `Lmml.Narrative.Renderer`.
  """

  alias Lmml.Bundle
  alias Lmml.Manifest

  @manifest_name "manifest.json"
  @message_prefix "message."
  @message_suffix ".json"

  @doc "The reserved embed name a session's metadata is stored under (manifest-compatible)."
  @spec manifest_name() :: String.t()
  def manifest_name, do: @manifest_name

  @typedoc "A message as stored in a session's `messages` list (string-keyed map)."
  @type message :: map()

  # ---------------------------------------------------------------------
  # Encoding
  # ---------------------------------------------------------------------

  @doc """
  Encodes `session_state` (a map with atom keys, as held by
  `Yoke.Brain.Session`) into the `.lmml` narrative text for a
  session identified by `session_id`.

  Returns `{:ok, narrative}` or `{:error, reason}`. The narrative embeds
  a `manifest.json` (metadata + snapshots) and one `message.N.json` embed
  per message.
  """
  @spec encode(map(), String.t()) :: {:ok, binary()} | {:error, term()}
  def encode(session_state, session_id) do
    session_state = sanitize_session_state(session_state)
    manifest = build_manifest(session_state, session_id)
    messages = Map.get(session_state, :messages, [])

    header = """
    # Yoke Conversation: #{session_id}

    This conversation is stored as an `lmml` narrative (a Markdown-superset
    markup). The authoritative message list and session metadata are carried
    as inline embeds below; the role headings are a human-readable view.

    @@@#{@manifest_name}
    #{escape_json(Yoke.Json.encode!(manifest, pretty: true))}
    @@@
    """

    body =
      messages
      |> Enum.with_index()
      |> Enum.map_join("\n\n", fn {msg, idx} ->
        role = String.upcase(Map.get(msg, "role") || "unknown")
        text = readable_text(msg)

        """
        ## #{role}

        #{text}

        @@@#{@message_prefix}#{idx}#{@message_suffix}
        #{escape_json(Yoke.Json.encode!(msg))}
        @@@
        """
      end)

    narrative = header <> "\n\n" <> body <> "\n"

    case Bundle.new_text("#{session_id}.lmml", narrative) do
      {:ok, _bundle} ->
        {:ok, narrative}

      {:error, reason} ->
        require Logger

        Logger.debug(
          "[SessionLmml] Bundle parser validation notice for '#{session_id}': #{inspect(reason, pretty: true, limit: :infinity)}. Saving narrative text directly."
        )

        {:ok, narrative}
    end
  rescue
    e ->
      require Logger
      stacktrace = Exception.format(:error, e, __STACKTRACE__)

      Logger.debug(
        "[SessionLmml] Exception during session encoding for '#{session_id}':\n#{stacktrace}"
      )

      case binding() |> Keyword.get(:narrative) do
        narrative when is_binary(narrative) ->
          Logger.debug(
            "[SessionLmml] Recovered constructed LMML narrative despite parser validation exception."
          )

          {:ok, narrative}

        _ ->
          {:error, Exception.message(e)}
      end
  end

  # The `@@@` sequence is the lmml inline-embed delimiter: the narrative
  # parser terminates an `@@@name ... @@@` block at the FIRST `@@@` it
  # encounters, with no escape mechanism. A message's content can legitimately
  # contain a literal `@@@` -- most commonly when a tool result reads a `.lmml`
  # file or a session export, which embeds its own `@@@manifest.json` /
  # `@@@message.N.json` markers. If that content were JSON-encoded verbatim
  # into an embed block, the nested `@@@` would truncate the embed early,
  # corrupting the whole narrative (save failures + undecodable files).
  #
  # Fix: before a JSON payload is written into an embed, escape every literal
  # `@@@` as `\u0040\u0040\u0040` (the valid JSON unicode escape for `@`). The
  # embed content then contains no delimiter, so parsing is safe; and because
  # `JSON.decode/1` (via `Yoke.Json.decode/1`) resolves `\u0040` back to `@`
  # automatically, a decode/load round-trip is lossless with NO decode-side
  # change needed.
  defp escape_json(json) when is_binary(json) do
    String.replace(json, "@@@", "\\u0040\\u0040\\u0040")
  end

  @doc """
  Decodes a `.lmml` narrative (or a parsed `Lmml.Bundle`) back into the
  string-keyed map shape `Yoke.Brain.SessionStore.load_session/2`
  returns: `%{"session_id", "model", "permission_mode", "step_count",
  "total_prompt_tokens", "total_completion_tokens", "updated_at",
  "messages", "snapshots"}`.

  Accepts either a `Lmml.Bundle.t()` or a raw narrative binary.
  """
  @spec decode(Bundle.t() | binary()) :: {:ok, map()} | {:error, term()}
  def decode(%Bundle{} = bundle) do
    with {:ok, messages} <- decode_messages(bundle),
         {:ok, manifest} <- decode_manifest(bundle) do
      all_messages =
        if messages != [] do
          messages
        else
          Map.get(manifest, "messages", [])
        end

      {:ok, Map.merge(manifest, %{"messages" => all_messages})}
    end
  end

  def decode(narrative) when is_binary(narrative) do
    case Bundle.new_text("session.lmml", narrative) do
      {:ok, bundle} ->
        decode(bundle)

      {:error, reason} ->
        require Logger

        Logger.debug(
          "[SessionLmml] Bundle parser notice on decode: #{inspect(reason)}. Falling back to regex embed extractor."
        )

        decode_narrative_regex(narrative)
    end
  end

  def decode(_), do: {:error, "Cannot decode: expected a narrative binary or Lmml.Bundle."}

  defp decode_narrative_regex(narrative) when is_binary(narrative) do
    embed_regex = ~r/@@@([^\r\n]+)[\r\n]+([\s\S]*?)[\r\n]+@@@/

    matches = Regex.scan(embed_regex, narrative)

    manifest_content =
      Enum.find_value(matches, fn
        [_, "manifest.json", content] -> content
        _ -> nil
      end)

    messages =
      matches
      |> Enum.filter(fn
        [_, name, _] ->
          String.starts_with?(name, @message_prefix) and String.ends_with?(name, @message_suffix)

        _ ->
          false
      end)
      |> Enum.sort_by(fn [_, name, _] ->
        idx_str =
          name
          |> String.replace_prefix(@message_prefix, "")
          |> String.replace_suffix(@message_suffix, "")

        case Integer.parse(idx_str) do
          {n, _} -> n
          _ -> -1
        end
      end)
      |> Enum.map(fn [_, _name, content] ->
        case Yoke.Json.decode(content) do
          {:ok, msg} -> msg
          _ -> %{}
        end
      end)

    case manifest_content do
      nil ->
        {:error, "Regex fallback failed: no manifest.json embed found in narrative."}

      json_str ->
        case Yoke.Json.decode(json_str) do
          {:ok, manifest} ->
            all_messages =
              if messages != [] do
                messages
              else
                Map.get(manifest, "messages", [])
              end

            {:ok, Map.merge(manifest, %{"messages" => all_messages})}

          {:error, err} ->
            {:error, "Failed to decode manifest.json embed: #{inspect(err)}"}
        end
    end
  end

  @doc """
  Validates a `.lmml` narrative binary or `Lmml.Bundle` using `Lmml.validate/1`.
  Returns `:ok` or `{:error, issues}` detailing any reference, zip entry, or embed name anomalies.
  """
  @spec validate(Bundle.t() | binary()) :: :ok | {:error, list()}
  def validate(%Bundle{} = bundle), do: Lmml.validate(bundle)

  def validate(narrative) when is_binary(narrative) do
    case Bundle.new_text("session.lmml", narrative) do
      {:ok, bundle} -> Lmml.validate(bundle)
      {:error, reason} -> {:error, [reason]}
    end
  end

  def validate(_), do: {:error, ["Invalid input for LMML validation"]}

  @doc """
  Converts a `.lmml` narrative or bundle to clean, human-readable Markdown
  using `Lmml.to_md/2` (replacing embed syntax with readable placeholders).
  """
  @spec to_markdown(Bundle.t() | binary(), keyword()) :: {:ok, binary()} | {:error, term()}
  def to_markdown(target, opts \\ [])

  def to_markdown(%Bundle{} = bundle, opts) do
    {:ok, Lmml.to_md(bundle, opts)}
  rescue
    e -> {:error, Exception.message(e)}
  end

  def to_markdown(narrative, opts) when is_binary(narrative) do
    case Bundle.new_text("session.lmml", narrative) do
      {:ok, bundle} -> {:ok, Lmml.to_md(bundle, opts)}
      {:error, reason} -> {:error, reason}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  def to_markdown(_target, _opts), do: {:error, "Invalid input for LMML to_markdown"}

  # ---------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------

  defp build_manifest(session_state, session_id) do
    %{
      "session_id" => session_id,
      "model" => Map.get(session_state, :model, "deepseek-chat"),
      "permission_mode" => to_string(Map.get(session_state, :permission_mode, :ask_confirm)),
      "step_count" => Map.get(session_state, :step_count, 0),
      "total_prompt_tokens" => Map.get(session_state, :total_prompt_tokens, 0),
      "total_completion_tokens" => Map.get(session_state, :total_completion_tokens, 0),
      "updated_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "snapshots" => serialize_snapshots(Map.get(session_state, :snapshots, []))
    }
  end

  defp serialize_snapshots(snapshots) when is_list(snapshots) do
    Enum.map(snapshots, fn s ->
      %{
        "id" => s[:id] || s["id"],
        "label" => s[:label] || s["label"],
        "timestamp" => s[:timestamp] || s["timestamp"],
        "model" => s[:model] || s["model"],
        "messages" => s[:messages] || s["messages"]
      }
    end)
  end

  defp serialize_snapshots(_), do: []

  defp decode_manifest(%Bundle{} = bundle) do
    case Lmml.manifest(bundle) do
      {:ok, nil} ->
        {:ok, default_manifest()}

      {:ok, %Manifest{data: data}} ->
        {:ok, normalize_manifest(data)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp default_manifest do
    %{
      "session_id" => nil,
      "model" => "deepseek-chat",
      "permission_mode" => "ask_confirm",
      "step_count" => 0,
      "total_prompt_tokens" => 0,
      "total_completion_tokens" => 0,
      "updated_at" => nil,
      "snapshots" => []
    }
  end

  defp normalize_manifest(data) do
    base = %{
      "session_id" => Map.get(data, "session_id"),
      "model" => Map.get(data, "model", "deepseek-chat"),
      "permission_mode" => Map.get(data, "permission_mode", "ask_confirm"),
      "step_count" => Map.get(data, "step_count", 0),
      "total_prompt_tokens" => Map.get(data, "total_prompt_tokens", 0),
      "total_completion_tokens" => Map.get(data, "total_completion_tokens", 0),
      "updated_at" => Map.get(data, "updated_at"),
      "snapshots" => Map.get(data, "snapshots", [])
    }

    case Map.get(data, "messages") do
      msgs when is_list(msgs) -> Map.put(base, "messages", msgs)
      _ -> base
    end
  end

  defp decode_messages(%Bundle{} = bundle) do
    bundle
    |> Lmml.embeds()
    |> Enum.filter(&embed_message?/1)
    |> Enum.sort_by(&embed_index/1)
    |> Enum.reduce_while({:ok, []}, fn embed, {:ok, acc} ->
      case Bundle.embed(bundle, embed.name) do
        {:ok, content} ->
          case Yoke.Json.decode(content) do
            {:ok, msg} when is_map(msg) -> {:cont, {:ok, acc ++ [msg]}}
            _ -> {:halt, {:error, {:invalid_message_embed, embed.name}}}
          end

        {:error, reason} ->
          {:halt, {:error, {embed.name, reason}}}
      end
    end)
  end

  defp embed_message?(%Lmml.Embed{name: name}) do
    String.starts_with?(name, @message_prefix) and String.ends_with?(name, @message_suffix)
  end

  defp embed_index(%Lmml.Embed{name: name}) do
    inner = String.replace_prefix(name, @message_prefix, "")
    inner = String.replace_suffix(inner, @message_suffix, "")

    case Integer.parse(inner) do
      {n, _} -> n
      :error -> -1
    end
  end

  # Human-readable prose for a message's `content`, mirroring
  # `Yoke.Brain.Session.message_content_text/1`: handles the
  # plain-string form and the multimodal array form (image_url / text
  # parts) used by vision models. Tool-call messages are checked first so
  # their `content` (often an empty string) doesn't shadow the call list.
  defp readable_text(%{"tool_calls" => calls}) when is_list(calls) do
    names =
      Enum.map_join(calls, ", ", fn call ->
        call |> Map.get("function", %{}) |> Map.get("name", "?")
      end)

    "*(tool calls: #{names})*"
  end

  defp readable_text(%{"content" => content}) when is_binary(content), do: content

  defp readable_text(%{"content" => content}) when is_list(content) do
    Enum.map_join(content, "\n", fn
      %{"text" => text} when is_binary(text) -> text
      %{"image_url" => %{"url" => url}} when is_binary(url) -> "[Image: #{url}]"
      _ -> ""
    end)
  end

  defp readable_text(_), do: ""

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
end
