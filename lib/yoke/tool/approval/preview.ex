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
    with true <- :erlang.external_size(operation) <= @maximum_bytes,
         {:ok, encoded} <- Jason.encode(operation, escape: :unicode_safe) do
      encoded
      |> String.replace(<<127>>, "\\u007f")
      |> bounded_result()
    else
      _invalid -> :unavailable
    end
  end

  def build(_operation), do: :unavailable

  @doc "Validates that a preview string strictly contains printable ASCII JSON without unescaped control codes."
  @spec validate(term()) :: {:ok, String.t() | nil | :unavailable} | {:error, String.t()}
  def validate(preview) when preview in [nil, :unavailable], do: {:ok, preview}

  def validate(preview) when is_binary(preview) and byte_size(preview) <= @maximum_bytes do
    with true <- Regex.match?(@printable_ascii, preview),
         {:ok, decoded} <- Jason.decode(preview),
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
