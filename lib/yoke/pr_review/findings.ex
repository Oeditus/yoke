defmodule Yoke.PRReview.Findings do
  @moduledoc """
  Parses and validates structured review findings without interpreting review prose.

  Explicit `<findings>` envelopes and legacy `json findings` fences take precedence
  over generic JSON fences. JSON is decoded before its closing delimiter is read,
  so delimiters appearing inside JSON strings cannot truncate a finding.
  """

  @marker ~r/<findings>|^[ \t]*```json(?:[ \t]+findings)?[ \t]*(?:\r?\n|\z)/m
  @closing_fence ~r/\A[ \t]*```[ \t]*(?:\r?\n|\z)/
  @skip_fence ~r/^[ \t]*```[ \t]*(?:\r?\n|\z)/m
  @severities ~w(high medium low info)

  @doc """
  Returns normalized atom-keyed findings, or a diagnostic for invalid input.

  Missing `kind` supports legacy informational praise without suggested fixes.
  Explicit endorsements never retain fix suggestions. No prose fallback is used.
  """
  @spec parse(term()) :: {:ok, [map()]} | {:error, String.t()}
  def parse(text) when is_binary(text) do
    if String.valid?(text) do
      with {:ok, explicit, generic} <- collect(text, [], []) do
        select_payload(explicit, generic)
      end
    else
      {:error, "Review output must be valid UTF-8."}
    end
  end

  def parse(_), do: {:error, "Review output must be a string."}

  defp collect(text, explicit, generic) do
    case Regex.run(@marker, text, return: :index) do
      [{offset, size}] ->
        marker = binary_part(text, offset, size)
        rest = binary_part(text, offset + size, byte_size(text) - offset - size)
        type = marker_type(marker)

        case decode_payload(rest, type) do
          {:ok, payload, tail} ->
            result = normalize(payload)

            if type == :generic do
              generic = if match?({:ok, _}, result), do: [result | generic], else: generic
              collect(tail, explicit, generic)
            else
              collect(tail, [result | explicit], generic)
            end

          :error when type == :generic ->
            collect(skip_generic(rest), explicit, generic)

          :error ->
            {:error, "Malformed explicit findings payload or missing closing delimiter."}
        end

      nil ->
        {:ok, explicit, generic}
    end
  end

  defp marker_type("<findings>"), do: :envelope

  defp marker_type(marker) do
    if String.contains?(marker, "findings"), do: :legacy, else: :generic
  end

  defp decode_payload(text, type) do
    # Prefix decoding delegates string escaping and JSON boundaries to OTP.
    # `null: nil` matches Yoke.Json's representation of nullable locations.
    {payload, _, tail} = :json.decode(text, nil, %{null: nil})

    case close_payload(String.trim_leading(tail), type) do
      {:ok, rest} -> {:ok, payload, rest}
      :error -> :error
    end
  rescue
    ArgumentError -> :error
    ErlangError -> :error
  end

  defp close_payload("</findings>" <> rest, :envelope), do: {:ok, rest}
  defp close_payload(_, :envelope), do: :error

  defp close_payload(text, _type) do
    case Regex.run(@closing_fence, text, return: :index) do
      [{0, size}] -> {:ok, binary_part(text, size, byte_size(text) - size)}
      nil -> :error
    end
  end

  defp skip_generic(text) do
    case Regex.run(@skip_fence, text, return: :index) do
      [{offset, size}] ->
        binary_part(text, offset + size, byte_size(text) - offset - size)

      nil ->
        ""
    end
  end

  defp select_payload([payload], _generic), do: payload

  defp select_payload([_, _ | _], _generic),
    do: {:error, "Multiple explicit findings payloads are ambiguous."}

  defp select_payload([], [payload]), do: payload

  defp select_payload([], [_, _ | _]),
    do: {:error, "Multiple generic findings payloads are ambiguous."}

  defp select_payload([], []), do: {:error, "No valid structured findings payload found."}

  defp normalize(payload) when is_list(payload) do
    payload
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {finding, index}, {:ok, acc} ->
      case normalize_finding(finding, index) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        :error -> {:halt, {:error, "Invalid finding at index #{index}."}}
      end
    end)
    |> case do
      {:ok, findings} -> {:ok, Enum.reverse(findings)}
      error -> error
    end
  end

  defp normalize(_), do: {:error, "Findings payload must be a JSON array."}

  defp normalize_finding(finding, index) when is_map(finding) do
    id = Map.get(finding, "id", index)
    file = Map.get(finding, "file")
    line = normalize_line(Map.get(finding, "line"))
    title = Map.get(finding, "title")
    description = Map.get(finding, "description")
    severity = normalize_label(Map.get(finding, "severity"))
    fix = Map.get(finding, "fix_suggestion", "")
    kind = finding_kind(finding, severity, fix)

    if is_integer(id) and id > 0 and nullable_file?(file) and line != :invalid and
         nonblank?(title) and nonblank?(description) and severity in @severities and
         is_binary(fix) and kind in ["issue", "endorsement"] do
      {:ok,
       %{
         id: id,
         file: file,
         line: line,
         title: title,
         description: description,
         severity: severity,
         kind: kind,
         fix_suggestion: if(kind == "endorsement", do: "", else: fix)
       }}
    else
      :error
    end
  end

  defp normalize_finding(_, _), do: :error

  defp finding_kind(finding, severity, fix) do
    case Map.fetch(finding, "kind") do
      {:ok, kind} ->
        normalize_label(kind)

      :error ->
        if severity == "info" and is_binary(fix) and String.trim(fix) == "",
          do: "endorsement",
          else: "issue"
    end
  end

  defp normalize_label(value) when is_binary(value),
    do: value |> String.trim() |> String.downcase()

  defp normalize_label(_), do: nil

  defp normalize_line(nil), do: nil
  defp normalize_line(value) when is_integer(value) and value > 0, do: value

  defp normalize_line(value) when is_binary(value) do
    if Regex.match?(~r/\A[0-9]+\z/, value) do
      normalize_line(String.to_integer(value))
    else
      :invalid
    end
  end

  defp normalize_line(_), do: :invalid

  defp nullable_file?(nil), do: true
  defp nullable_file?(value), do: nonblank?(value)

  defp nonblank?(value), do: is_binary(value) and String.trim(value) != ""
end
