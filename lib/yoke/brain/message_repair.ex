defmodule Yoke.Brain.MessageRepair do
  @moduledoc """
  Repairs message histories so they satisfy the provider's tool-call contract.

  A chat-completions request requires that every `tool_calls` entry on an
  assistant message be answered by a `tool` message carrying the matching
  `tool_call_id`, in order. A cancelled turn, a crashed tool task, or a
  resumed session can all leave that contract broken, and the provider then
  rejects the *entire* request with HTTP 400 -- losing the conversation.

  Two strategies live here, tried in order by `Yoke.Brain.Session`:

    * `repair/1` -- the surgical one. Inserts a placeholder `tool` response for
      any unanswered call and converts an orphaned `tool` message into a plain
      user message. Preserves the conversation shape.
    * `flatten_tool_roles/1` -- the last resort. Rewrites every `tool` message
      as a user message and drops `tool_calls` entirely, so a provider that
      rejects the repaired shape still gets a valid request.

  Extracted from `Yoke.Brain.Session` because both are pure list transforms
  with no dependency on session state, and were previously reachable only
  through a live actor.
  """

  @doc """
  Repairs malformed tool sequences in `messages`.

  Returns a new list in which every assistant `tool_calls` block is followed by
  exactly one `tool` response per call.
  """
  @spec repair([map()]) :: [map()]
  def repair(messages) when is_list(messages) do
    {acc, pending} =
      Enum.reduce(messages, {[], []}, fn msg, {acc_messages, pending_ids} ->
        role = Map.get(msg, "role") || Map.get(msg, :role)
        calls = Map.get(msg, "tool_calls") || Map.get(msg, :tool_calls)

        cond do
          role == "tool" ->
            call_id = Map.get(msg, "tool_call_id") || Map.get(msg, :tool_call_id)

            if call_id != nil and call_id in pending_ids do
              {acc_messages ++ [msg], List.delete(pending_ids, call_id)}
            else
              {acc_messages ++ [orphan_to_user(msg, call_id)], pending_ids}
            end

          role == "assistant" and is_list(calls) and calls != [] ->
            acc_messages = fill_pending(acc_messages, pending_ids)

            new_ids =
              calls
              |> Enum.map(fn tc -> Map.get(tc, "id") || Map.get(tc, :id) end)
              |> Enum.reject(&is_nil/1)

            {acc_messages ++ [msg], new_ids}

          true ->
            {fill_pending(acc_messages, pending_ids) ++ [msg], []}
        end
      end)

    fill_pending(acc, pending)
  end

  def repair(_), do: []

  @doc """
  Rewrites every `tool` message as a user message and removes `tool_calls`.

  Used only after `repair/1`'s output was still rejected by the provider.
  """
  @spec flatten_tool_roles([map()]) :: [map()]
  def flatten_tool_roles(messages) when is_list(messages) do
    Enum.map(messages, fn msg ->
      role = Map.get(msg, "role") || Map.get(msg, :role)
      calls = Map.get(msg, "tool_calls") || Map.get(msg, :tool_calls)

      cond do
        role == "tool" ->
          call_id = Map.get(msg, "tool_call_id") || Map.get(msg, :tool_call_id) || "unknown"
          content = Map.get(msg, "content") || Map.get(msg, :content, "")

          %{"role" => "user", "content" => "[Tool Output #{call_id}]: #{content}"}

        role == "assistant" and is_list(calls) ->
          content = Map.get(msg, "content") || ""

          msg
          |> Map.drop(["tool_calls", :tool_calls])
          |> Map.put("content", content)

        true ->
          msg
      end
    end)
  end

  def flatten_tool_roles(_), do: []

  defp orphan_to_user(msg, call_id) do
    content = Map.get(msg, "content") || Map.get(msg, :content, "")

    %{
      "role" => "user",
      "content" => "[Tool Output #{call_id || "unknown"}]: #{content}"
    }
  end

  defp fill_pending(messages, []), do: messages

  defp fill_pending(messages, pending_ids) when is_list(pending_ids) do
    messages ++
      Enum.map(pending_ids, fn id ->
        %{
          "role" => "tool",
          "tool_call_id" => id,
          "content" => "SYSTEM NOTICE: Tool execution result unavailable."
        }
      end)
  end
end
