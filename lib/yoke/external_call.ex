defmodule Yoke.ExternalCall do
  @moduledoc """
  Standardized wrapper for external third-party service calls (LLMs, MCP servers, HTTP fetches).
  Measures duration, logs telemetry, and classifies errors into `:timeout`, `:transport`, or `:error`.
  """
  require Logger

  @type error_classification :: :timeout | :transport | :error

  @doc """
  Executes an external call `fun`, recording telemetry and error classification.

  ## Parameters
    - `service`: atom or string identifying the external service (e.g. `:deepseek_api`, `:mcp_server`, `:http_fetch`)
    - `meta`: key-value metadata map or keyword list (e.g. `[endpoint: ..., model: ...]`)
    - `fun`: 0-arity function performing the actual call
  """
  def run(service, meta, fun, _opts \\ []) when is_function(fun, 0) do
    meta_map = Map.new(meta)
    start_time = System.monotonic_time(:millisecond)

    try do
      case fun.() do
        {:ok, _result} = ok_res ->
          duration_ms = System.monotonic_time(:millisecond) - start_time
          log_success(service, meta_map, duration_ms)
          emit_telemetry(service, :ok, duration_ms, meta_map)
          ok_res

        {:error, reason} = err_res ->
          duration_ms = System.monotonic_time(:millisecond) - start_time
          classification = classify_error(reason)
          log_failure(service, meta_map, classification, reason, duration_ms)
          emit_telemetry(service, classification, duration_ms, meta_map)
          err_res

        other_res ->
          duration_ms = System.monotonic_time(:millisecond) - start_time
          log_success(service, meta_map, duration_ms)
          emit_telemetry(service, :ok, duration_ms, meta_map)
          other_res
      end
    catch
      kind, reason ->
        duration_ms = System.monotonic_time(:millisecond) - start_time
        classification = classify_error(reason)
        log_failure(service, meta_map, classification, {kind, reason}, duration_ms)
        emit_telemetry(service, classification, duration_ms, meta_map)
        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  @doc "Classifies an error payload into `:timeout`, `:transport`, or `:error`."
  def classify_error(reason) do
    case reason do
      :timeout ->
        :timeout

      %{reason: :timeout} ->
        :timeout

      {:timeout, _} ->
        :timeout

      reason_str when is_binary(reason_str) ->
        cond do
          String.contains?(
            reason_str,
            ["timeout", "timed out", "econnrefused", "connect_timeout"]
          ) ->
            :timeout

          String.contains?(
            reason_str,
            ["nxdomain", "nodedown", "unreachable", "econnreset", "closed"]
          ) ->
            :transport

          true ->
            :error
        end

      {:badrpc, :nodedown} ->
        :transport

      :econnrefused ->
        :transport

      :nxdomain ->
        :transport

      _ ->
        :error
    end
  end

  defp log_success(service, meta, duration_ms) do
    Logger.debug("☏  [✓ #{service} #{duration_ms}ms] #{inspect(meta)}")
  end

  defp log_failure(service, meta, classification, reason, duration_ms) do
    msg =
      "☏  [✗ #{service} #{classification} #{duration_ms}ms] #{inspect(reason)} | #{inspect(meta)}"

    case classification do
      :timeout -> Logger.warning(msg)
      :transport -> Logger.warning(msg)
      :error -> Logger.error(msg)
    end
  end

  defp emit_telemetry(service, status, duration_ms, meta) do
    if Code.ensure_loaded?(:telemetry) and function_exported?(:telemetry, :execute, 3) do
      :telemetry.execute(
        [:yoke, :external_call, service],
        %{duration_ms: duration_ms},
        Map.merge(meta, %{status: status})
      )
    end
  rescue
    _ -> :ok
  end
end
