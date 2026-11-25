defmodule Yoke.Client.RequestDiagnostics do
  @moduledoc """
  Byte-level description of an outgoing provider request.

  Issue #22 shows why this is needed: direct DeepSeek requests failed with
  `%Req.TransportError{reason: :closed}` only once the request body grew to
  roughly 100 KB, and the failure surfaced as an opaque transport error with
  no indication of how large the request was. Yoke could not tell the user
  whether the disconnect correlated with payload size, tool count, or a single
  oversized message.

  This module computes a metadata-only summary of a request body:

    * total serialized payload bytes,
    * message count and the largest message size,
    * tool count and total tool-definition bytes,
    * the largest single message's role and index.

  It never includes message content, tool arguments, or credentials, so the
  summary is safe to log and safe to put in an error message. Sizes are
  measured on the serialized JSON that is actually sent, which is the number
  that matters to a transport that closes on large uploads.
  """

  @type t :: %__MODULE__{
          payload_bytes: non_neg_integer(),
          message_count: non_neg_integer(),
          message_bytes: non_neg_integer(),
          largest_message_bytes: non_neg_integer(),
          largest_message_role: String.t() | nil,
          largest_message_index: non_neg_integer() | nil,
          tool_count: non_neg_integer(),
          tool_bytes: non_neg_integer()
        }

  defstruct payload_bytes: 0,
            message_count: 0,
            message_bytes: 0,
            largest_message_bytes: 0,
            largest_message_role: nil,
            largest_message_index: nil,
            tool_count: 0,
            tool_bytes: 0

  @doc """
  Builds diagnostics for a request body and its formatted tool definitions.

  `body` is the map that will be JSON-encoded and sent; `formatted_tools` is
  the already-formatted tool list (as produced for the `"tools"` field).
  """
  @spec build(map(), list()) :: t()
  def build(body, formatted_tools) when is_map(body) and is_list(formatted_tools) do
    messages = Map.get(body, "messages") || Map.get(body, :messages) || []

    {message_bytes, largest} = measure_messages(messages)
    tool_bytes = Enum.reduce(formatted_tools, 0, &(byte_size(encode(&1)) + &2))

    %__MODULE__{
      payload_bytes: byte_size(encode(body)),
      message_count: length(messages),
      message_bytes: message_bytes,
      largest_message_bytes: largest.bytes,
      largest_message_role: largest.role,
      largest_message_index: largest.index,
      tool_count: length(formatted_tools),
      tool_bytes: tool_bytes
    }
  end

  @doc """
  Renders diagnostics as a single compact, content-free line.

  Example: `"payload 108000B, 42 messages (largest 84000B role=tool #7),
  tools 6 (12000B)"`.
  """
  @spec describe(t()) :: String.t()
  def describe(%__MODULE__{} = diag) do
    "payload #{diag.payload_bytes}B, " <>
      "#{diag.message_count} #{pluralize(diag.message_count, "message")}" <>
      largest_fragment(diag) <>
      ", tools #{diag.tool_count} (#{diag.tool_bytes}B)"
  end

  @doc """
  Renders diagnostics as a map of plain values, for structured logging.
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = diag) do
    Map.from_struct(diag)
  end

  defp largest_fragment(%__MODULE__{message_count: 0}), do: ""

  defp largest_fragment(%__MODULE__{} = diag) do
    " (largest #{diag.largest_message_bytes}B role=#{diag.largest_message_role || "unknown"}" <>
      " ##{diag.largest_message_index})"
  end

  defp measure_messages(messages) do
    messages
    |> Enum.with_index()
    |> Enum.reduce({0, %{bytes: 0, role: nil, index: nil}}, fn {message, index},
                                                               {total, largest} ->
      bytes = byte_size(encode(message))
      total = total + bytes

      if bytes > largest.bytes do
        {total, %{bytes: bytes, role: message_role(message), index: index}}
      else
        {total, largest}
      end
    end)
  end

  defp message_role(%{"role" => role}) when is_binary(role), do: role
  defp message_role(%{role: role}) when is_binary(role), do: role
  defp message_role(_), do: nil

  defp encode(term) do
    case Yoke.Json.encode(term) do
      {:ok, encoded} -> encoded
      _ -> inspect(term)
    end
  end

  defp pluralize(1, word), do: word
  defp pluralize(_count, word), do: word <> "s"
end
