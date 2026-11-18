defmodule Yoke.Tool.Approval.Preview do
  @moduledoc """
  Builds bounded, lossless operation details for interactive approval displays.
  Complete previews are ASCII JSON objects, limited to 16 KiB. Control and
  non-ASCII characters are escaped, not removed. Invalid or oversized operations
  return `:unavailable`, never partial or misleading content.
  """

  @maximum_bytes 16_384
  @printable_ascii ~r/\A[\x20-\x7E]+\z/

  @type t :: String.t() | :unavailable

  @doc "Encodes a bounded operation object or marks its complete preview unavailable."
  @spec build(term()) :: t()
  def build(operation) when is_map(operation) do
    # The preview must be pure printable ASCII, so every non-ASCII code point is
    # escaped before encoding. `Yoke.Json` (built-in `JSON`) has no
    # `escape: :unicode_safe` option, so the escaping happens here.
    with true <- :erlang.external_size(operation) <= @maximum_bytes,
         {:ok, encoded} <- Yoke.Json.encode(ascii_escape(operation)) do
      encoded
      |> String.replace(<<127>>, "\\u007f")
      |> bounded_result()
    else
      _invalid -> :unavailable
    end
  end

  def build(_operation), do: :unavailable

  # Replaces every non-printable-ASCII code point with its `\uXXXX` escape so
  # the encoded JSON contains only bytes in 0x20..0x7E (plus the escapes).
  defp ascii_escape(value) when is_binary(value) do
    for <<cp::utf8 <- value>>, into: "" do
      if cp >= 0x20 and cp <= 0x7E do
        <<cp::utf8>>
      else
        "\\u" <> String.pad_leading(Integer.to_string(cp, 16), 4, "0")
      end
    end
  end

  defp ascii_escape(value) when is_list(value), do: Enum.map(value, &ascii_escape/1)

  defp ascii_escape(value) when is_map(value) and not is_struct(value) do
    Map.new(value, fn {k, v} -> {ascii_escape(k), ascii_escape(v)} end)
  end

  defp ascii_escape(value) when is_atom(value), do: ascii_escape(Atom.to_string(value))
  defp ascii_escape(value), do: value

  @doc "Validates that a preview string strictly contains printable ASCII JSON without unescaped control codes."
  @spec validate(term()) :: {:ok, String.t() | nil | :unavailable} | {:error, String.t()}
  def validate(preview) when preview in [nil, :unavailable], do: {:ok, preview}

  def validate(preview) when is_binary(preview) and byte_size(preview) <= @maximum_bytes do
    with true <- Regex.match?(@printable_ascii, preview),
         {:ok, decoded} <- Yoke.Json.decode(preview),
         true <- is_map(decoded) do
      {:ok, preview}
    else
      _ -> {:error, "preview must be bounded printable ASCII JSON"}
    end
  end

  def validate(_preview), do: {:error, "preview must be bounded printable ASCII JSON"}

  defp bounded_result(encoded) when byte_size(encoded) <= @maximum_bytes do
    if Regex.match?(@printable_ascii, encoded) do
      encoded
    else
      :unavailable
    end
  end

  defp bounded_result(_encoded), do: :unavailable
end
