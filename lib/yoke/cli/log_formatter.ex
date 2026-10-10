defmodule Yoke.CLI.LogFormatter do
  @moduledoc """
  Custom Erlang/Elixir Logger formatter producing clean, compact Yoke-style status lines.
  Formats log events with colored geometric circles (blue/yellow/red) without timestamp clutter.
  Suppresses noisy low-level socket transport chatter and handles raw mode CRLF formatting.
  """

  alias Yoke.CLI.Formatter
  alias Yoke.CLI.LineEditor
  alias Yoke.CLI.Spinner
  alias Yoke.CLI.TerminalOwner

  @noisy_patterns ~r/(\[HANDLER\]|\[ACCEPT LOOP\]|Client connected|Client disconnected|Client connection|connection timeout|Waiting for data|Processing message|Sending response|Response sent|AI Cache|SessionLmml)/i

  @doc "Formats Erlang/Elixir log events into Yoke-style single lines."
  def format(%{level: level, msg: msg}, _config) do
    formatted_msg = format_message(msg) |> String.trim()

    if level == :error or String.contains?(formatted_msg, "Task.Supervisor") or
         String.contains?(formatted_msg, "terminating") do
      write_error_to_lmml(level, formatted_msg)
    end

    if noisy_log?(formatted_msg) do
      ""
    else
      circle =
        case level do
          :error -> IO.ANSI.red() <> "●" <> IO.ANSI.reset()
          :warning -> IO.ANSI.yellow() <> "●" <> IO.ANSI.reset()
          :warn -> IO.ANSI.yellow() <> "●" <> IO.ANSI.reset()
          :info -> IO.ANSI.blue() <> "●" <> IO.ANSI.reset()
          :debug -> IO.ANSI.blue() <> "●" <> IO.ANSI.reset()
          _ -> IO.ANSI.blue() <> "●" <> IO.ANSI.reset()
        end

      base_line =
        if String.starts_with?(formatted_msg, "\e") or String.starts_with?(formatted_msg, "●") or
             String.starts_with?(formatted_msg, "⚡") or String.starts_with?(formatted_msg, "󱐋") or
             String.starts_with?(formatted_msg, "◈") or String.starts_with?(formatted_msg, "❯") or
             String.starts_with?(formatted_msg, "⟡") do
          "#{formatted_msg}\r\n"
        else
          "#{circle} #{formatted_msg}\r\n"
        end
        |> truncate_to_terminal()

      cond do
        Spinner.active?() and not Spinner.paused?() ->
          current_spinner = Spinner.current_line()
          "\r\e[2K" <> base_line <> "\r" <> current_spinner

        TerminalOwner.active?() ->
          TerminalOwner.interject(base_line)
          ""

        true ->
          base_line
      end
    end
  rescue
    _ -> ""
  end

  @doc "Installs the custom LogFormatter on standard Erlang/Elixir logger handler."
  def install do
    :logger.set_handler_config(:default, :formatter, {__MODULE__, %{}})
  rescue
    _ -> :error
  end

  defp write_error_to_lmml(level, formatted_msg) do
    cwd = System.get_env("YOKE_PROJECT_DIR") || System.get_env("PWD") || File.cwd!()
    dir = Path.join(cwd, ".yoke")
    File.mkdir_p!(dir)
    file_path = Path.join(dir, "ERRORS_TO_FIX.lmml")
    timestamp = DateTime.utc_now() |> DateTime.to_iso8601()
    safe_msg = Formatter.sanitize_utf8(formatted_msg)

    entry = """

    <!-- error_entry -->
    ## [#{timestamp}] Level: #{level}
    ```
    #{String.trim(safe_msg)}
    ```
    """

    File.write(file_path, entry, [:append])
  rescue
    _ -> :ok
  end

  defp truncate_to_terminal(line) do
    if LineEditor.expand_tool_calls?() do
      to_crlf(line)
    else
      content = String.trim_trailing(line, "\r\n")
      budget = max(terminal_cols() - 2, 1)

      content
      |> String.split("\n")
      |> Enum.map_join("\n", &LineEditor.truncate_to_width(&1, budget))
      |> Kernel.<>("\r\n")
    end
  end

  defp to_crlf(line) do
    if String.ends_with?(line, "\r\n") do
      line
    else
      line |> String.trim_trailing("\n") |> String.replace("\n", "\r\n") |> Kernel.<>("\r\n")
    end
  end

  defp terminal_cols do
    case :io.columns() do
      {:ok, c} when is_integer(c) and c > 10 -> c
      _ -> 120
    end
  end

  defp noisy_log?(msg) when is_binary(msg) do
    Regex.match?(@noisy_patterns, msg)
  end

  defp format_message({:string, chardata}), do: to_string(chardata)

  defp format_message({:report, %{label: {Task.Supervisor, :terminating}, report: rep}})
       when is_map(rep) do
    func_str = format_fun(Map.get(rep, :function))
    args_str = inspect(Map.get(rep, :args, []))
    reason_str = inspect(Map.get(rep, :reason, :normal))
    pid_str = inspect(Map.get(rep, :pid))

    """
    Task.Supervisor worker process terminating:
      ● Function: #{func_str}
      ● Reason:   #{reason_str}
      ● Args:     #{args_str}
      ● Worker:   #{pid_str}
    """
  end

  defp format_message({:report, %{label: label, report: rep}}) when is_map(rep) do
    details =
      Enum.map_join(rep, "\n  ● ", fn {k, v} ->
        "#{k}: #{format_val(v)}"
      end)

    "[#{inspect(label)}]\n  ● #{details}"
  end

  defp format_message({:report, report}) when is_map(report) do
    Enum.map_join(report, "\n  ● ", fn {k, v} -> "#{k}: #{format_val(v)}" end)
  end

  defp format_message({:report, report}), do: inspect(report)

  defp format_message({format, args}) when is_list(format) or is_binary(format) do
    :io_lib.format(format, args) |> to_string()
  rescue
    _ -> inspect({format, args})
  end

  defp format_message(msg) when is_binary(msg), do: msg
  defp format_message(msg), do: inspect(msg)

  defp format_fun(fun) when is_function(fun) do
    case Function.info(fun) do
      [_ | _] = info ->
        mod = Keyword.get(info, :module)
        name = Keyword.get(info, :name)
        arity = Keyword.get(info, :arity)
        "#{inspect(mod)}.#{name}/#{arity}"

      _ ->
        inspect(fun)
    end
  end

  defp format_fun(fun), do: inspect(fun)

  defp format_val(val) when is_function(val), do: format_fun(val)
  defp format_val(val), do: inspect(val)
end
