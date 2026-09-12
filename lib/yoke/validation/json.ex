defmodule Yoke.Validation.JSON do
  @moduledoc """
  Bounded, zero-dependency JSON schema and arguments validator.
  Enforces structural bounds (nesting depth, map keys, string sizes, collection counts)
  and validates tool arguments against parameter schemas.
  """

  @max_nesting_depth 10
  @max_string_bytes 10_485_760
  @max_object_keys 500
  @max_array_items 50_000

  @doc "Validates an object structure against nesting and size limits."
  @spec validate_object(term()) :: :ok | {:error, String.t()}
  def validate_object(value) do
    validate_value(value, 0)
  end

  @doc "Validates tool call arguments against a declared JSON schema."
  @spec validate_arguments(map(), map()) :: :ok | {:error, String.t()}
  def validate_arguments(schema, arguments) when is_map(schema) and is_map(arguments) do
    with :ok <- validate_object(arguments),
         :ok <- check_required(schema, arguments),
         do: check_properties(schema, arguments)
  end

  def validate_arguments(_schema, _arguments) do
    {:error, "schema and arguments must be maps"}
  end

  defp validate_value(_value, depth) when depth > @max_nesting_depth do
    {:error, "JSON structure exceeds maximum nesting depth of #{@max_nesting_depth}"}
  end

  defp validate_value(str, _depth) when is_binary(str) do
    if byte_size(str) <= @max_string_bytes do
      :ok
    else
      {:error, "String byte size exceeds limit"}
    end
  end

  defp validate_value(map, depth) when is_map(map) do
    if map_size(map) <= @max_object_keys do
      Enum.reduce_while(map, :ok, fn {k, v}, _acc ->
        if is_binary(k) do
          case validate_value(v, depth + 1) do
            :ok -> {:cont, :ok}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        else
          {:halt, {:error, "Map keys must be strings"}}
        end
      end)
    else
      {:error, "Object key count exceeds maximum of #{@max_object_keys}"}
    end
  end

  defp validate_value(list, depth) when is_list(list) do
    if length(list) <= @max_array_items do
      Enum.reduce_while(list, :ok, fn elem, _acc ->
        case validate_value(elem, depth + 1) do
          :ok -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    else
      {:error, "Array item count exceeds maximum of #{@max_array_items}"}
    end
  end

  defp validate_value(num, _depth) when is_number(num), do: :ok
  defp validate_value(bool, _depth) when is_boolean(bool), do: :ok
  defp validate_value(nil, _depth), do: :ok
  defp validate_value(other, _depth), do: {:error, "Unsupported type: #{inspect(other)}"}

  defp check_required(schema, arguments) do
    required = Map.get(schema, "required") || Map.get(schema, :required) || []

    missing =
      Enum.filter(required, fn req ->
        req_str = to_string(req)

        not Map.has_key?(arguments, req_str) and
          not Map.has_key?(arguments, String.to_atom(req_str))
      end)

    if missing == [] do
      :ok
    else
      {:error, "Missing required argument(s): #{Enum.join(missing, ", ")}"}
    end
  end

  defp check_properties(schema, arguments) do
    props = Map.get(schema, "properties") || Map.get(schema, :properties) || %{}

    Enum.reduce_while(arguments, :ok, fn {k, v}, _acc ->
      k_str = to_string(k)
      prop_schema = Map.get(props, k_str) || Map.get(props, String.to_atom(k_str))

      if prop_schema do
        case validate_property_type(prop_schema, v) do
          :ok -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, "Invalid argument '#{k_str}': #{reason}"}}
        end
      else
        :ok
      end
    end)
  end

  defp validate_property_type(prop_schema, value) when is_map(prop_schema) do
    expected_type = Map.get(prop_schema, "type") || Map.get(prop_schema, :type)

    case expected_type do
      "string" when is_binary(value) -> :ok
      "integer" when is_integer(value) -> :ok
      "number" when is_number(value) -> :ok
      "boolean" when is_boolean(value) -> :ok
      "array" when is_list(value) -> :ok
      "object" when is_map(value) -> :ok
      nil -> :ok
      other -> {:error, "expected type #{inspect(other)}, got #{inspect(value)}"}
    end
  end

  defp validate_property_type(_prop_schema, _value), do: :ok
end
