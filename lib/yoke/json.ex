defmodule Yoke.Json do
  @moduledoc """
  Thin wrapper around Elixir's built-in `JSON` module (Elixir 1.18+ /
  OTP 27+), replacing the former direct `:jason` dependency for Yoke's own
  JSON encoding/decoding needs.

  `JSON.encode!/1` only produces compact output -- there is no built-in
  pretty-printing option -- so this module adds a small hand-rolled
  pretty-printer (`encode!/2` and `encode/2` with `pretty: true`) for the
  human-edited/diffed files Yoke writes to disk (config, rules, session
  manifests). Everything else delegates straight to `JSON`, so string
  escaping and scalar encoding always go through the standard library's
  own (spec-conformant) implementation.
  """

  @doc "Decodes a JSON binary. See `JSON.decode/1`."
  @spec decode(binary()) :: {:ok, term()} | {:error, term()}
  defdelegate decode(binary), to: JSON

  @doc "Decodes a JSON binary, raising on error. See `JSON.decode!/1`."
  @spec decode!(binary()) :: term()
  defdelegate decode!(binary), to: JSON

  @doc """
  Encodes `term` to a JSON binary.

  Pass `pretty: true` to indent the output (2 spaces per level) for
  human-edited/diffed files; omitted (or `false`) produces the same
  compact output as `JSON.encode!/1`.

  If `term` contains invalid UTF-8 bytes that cause `:json.encode` to fail
  with `{:invalid_byte, _}`, automatically scrubs the invalid bytes using
  `sanitize_utf8/1` and retries encoding.
  """
  @spec encode!(term(), keyword()) :: binary()
  def encode!(term, opts \\ []) do
    do_encode!(term, opts)
  rescue
    e in ErlangError ->
      case e.original do
        {:invalid_byte, _} -> do_encode!(sanitize_utf8(term), opts)
        _ -> reraise e, __STACKTRACE__
      end
  end

  defp do_encode!(term, opts) do
    if Keyword.get(opts, :pretty, false) do
      pretty_encode!(term, 0)
    else
      JSON.encode!(term)
    end
  end

  @doc """
  Same as `encode!/2`, but returns `{:ok, binary}` / `{:error, exception}`
  instead of raising -- mirrors `Jason.encode/2`'s shape for `with`-based
  call sites.
  """
  @spec encode(term(), keyword()) :: {:ok, binary()} | {:error, Exception.t()}
  def encode(term, opts \\ []) do
    {:ok, encode!(term, opts)}
  rescue
    e -> {:error, e}
  end

  @doc """
  Recursively traverses maps, lists, and binaries within data structures,
  replacing or scrubbing any invalid UTF-8 byte sequences with valid UTF-8.
  Safe for structs, primitives, and deeply nested session payloads.
  """
  @spec sanitize_utf8(term()) :: term()
  def sanitize_utf8(binary) when is_binary(binary) do
    if String.valid?(binary) do
      binary
    else
      scrub_utf8(binary, "")
    end
  end

  def sanitize_utf8(list) when is_list(list), do: Enum.map(list, &sanitize_utf8/1)

  def sanitize_utf8(map) when is_map(map) and not is_struct(map) do
    Map.new(map, fn {k, v} -> {sanitize_utf8(k), sanitize_utf8(v)} end)
  end

  def sanitize_utf8(%struct{} = s) do
    fields = Map.from_struct(s) |> sanitize_utf8()
    struct(struct, fields)
  rescue
    _ -> s
  end

  def sanitize_utf8(other), do: other

  defp scrub_utf8(<<>>, acc), do: acc

  defp scrub_utf8(str, acc) when is_binary(str) do
    case :unicode.characters_to_binary(str, :utf8, :utf8) do
      cleaned when is_binary(cleaned) ->
        acc <> cleaned

      {:error, valid, <<_bad_byte, rest::binary>>} ->
        scrub_utf8(rest, acc <> valid)

      {:error, valid, <<>>} ->
        acc <> valid

      {:incomplete, valid, _bad} ->
        acc <> valid
    end
  end

  # ---------------------------------------------------------------------
  # Pretty-printer -- walks the already-decoded Elixir term and builds the
  # indented structure itself, delegating every leaf (string/number/
  # boolean/nil/atom) to `JSON.encode!/1` so escaping stays spec-correct.
  # ---------------------------------------------------------------------

  defp pretty_encode!(map, _indent)
       when is_map(map) and not is_struct(map) and map_size(map) == 0,
       do: "{}"

  defp pretty_encode!(map, indent) when is_map(map) and not is_struct(map) do
    inner = indent_str(indent + 1)
    outer = indent_str(indent)

    entries =
      Enum.map_join(map, ",\n", fn {k, v} ->
        key_str = to_string(k)

        encoded_key =
          try do
            JSON.encode!(key_str)
          rescue
            e in ErlangError ->
              case e.original do
                {:invalid_byte, _} -> JSON.encode!(sanitize_utf8(key_str))
                _ -> reraise e, __STACKTRACE__
              end
          end

        "#{inner}#{encoded_key}: #{pretty_encode!(v, indent + 1)}"
      end)

    "{\n#{entries}\n#{outer}}"
  end

  defp pretty_encode!([], _indent), do: "[]"

  defp pretty_encode!(list, indent) when is_list(list) do
    inner = indent_str(indent + 1)
    outer = indent_str(indent)

    entries =
      Enum.map_join(list, ",\n", fn v -> "#{inner}#{pretty_encode!(v, indent + 1)}" end)

    "[\n#{entries}\n#{outer}]"
  end

  # Catches scalars (string/number/boolean/nil) as well as any struct
  # (Date/Time/DateTime/NaiveDateTime/Duration, etc.) -- structs are maps,
  # but they must NOT go through the map-indenting clause above, since
  # `JSON.Encoder` already has correct, purpose-built implementations for
  # them (e.g. ISO 8601 strings for calendar types).
  defp pretty_encode!(scalar, _indent) do
    JSON.encode!(scalar)
  rescue
    e in ErlangError ->
      case e.original do
        {:invalid_byte, _} when is_binary(scalar) ->
          JSON.encode!(sanitize_utf8(scalar))

        _ ->
          reraise e, __STACKTRACE__
      end
  end

  defp indent_str(level), do: String.duplicate("  ", level)
end
