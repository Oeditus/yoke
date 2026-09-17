defmodule Yoke.Clipboard do
  @moduledoc """
  Cross-platform utility for inspecting and fetching system clipboard content,
  supporting both image binary payloads and plain text text selections across
  Linux (Wayland/X11), macOS, and Windows.
  """

  @doc """
  Attempts to read image data (PNG or JPEG) from the OS clipboard.

  Returns `{:ok, mime_type, binary_bytes}` when an image is present on the
  clipboard, or `{:error, reason}` when no image is found or no supported
  clipboard CLI tool is available.
  """
  @spec fetch_image() :: {:ok, String.t(), binary()} | {:error, term()}
  def fetch_image do
    cond do
      # 1. Wayland (Linux) via `wl-paste`
      exec = System.find_executable("wl-paste") ->
        fetch_wl_paste_image(exec)

      # 2. X11 (Linux) via `xclip`
      exec = System.find_executable("xclip") ->
        fetch_xclip_image(exec)

      # 3. macOS via `pngpaste`
      exec = System.find_executable("pngpaste") ->
        fetch_pngpaste_image(exec)

      # 4. macOS via `osascript`
      exec = System.find_executable("osascript") ->
        fetch_osascript_image(exec)

      # 5. Windows via `powershell`
      exec = System.find_executable("powershell.exe") || System.find_executable("powershell") ->
        fetch_powershell_image(exec)

      true ->
        {:error,
         "No supported system clipboard utility found (wl-paste, xclip, pngpaste, osascript, or powershell)."}
    end
  end

  @doc """
  Attempts to read plain text from the OS clipboard.

  Returns `{:ok, text}` or `{:error, reason}`.
  """
  @spec fetch_text() :: {:ok, String.t()} | {:error, term()}
  def fetch_text do
    cond do
      exec = System.find_executable("wl-paste") ->
        case System.cmd(exec, [], stderr_to_stdout: true) do
          {out, 0} when byte_size(out) > 0 -> {:ok, out}
          _ -> {:error, "Clipboard is empty or contains non-text content."}
        end

      exec = System.find_executable("xclip") ->
        case System.cmd(exec, ["-selection", "clipboard", "-o"], stderr_to_stdout: true) do
          {out, 0} when byte_size(out) > 0 -> {:ok, out}
          _ -> {:error, "Clipboard is empty or contains non-text content."}
        end

      exec = System.find_executable("pbpaste") ->
        case System.cmd(exec, [], stderr_to_stdout: true) do
          {out, 0} when byte_size(out) > 0 -> {:ok, out}
          _ -> {:error, "Clipboard is empty or contains non-text content."}
        end

      exec = System.find_executable("powershell.exe") || System.find_executable("powershell") ->
        case System.cmd(exec, ["-command", "Get-Clipboard"], stderr_to_stdout: true) do
          {out, 0} when byte_size(out) > 0 -> {:ok, out}
          _ -> {:error, "Clipboard is empty or contains non-text content."}
        end

      true ->
        {:error, "No supported system clipboard utility found."}
    end
  end

  # --- Private Helpers ---

  defp fetch_wl_paste_image(exec) do
    case System.cmd(exec, ["-t", "image/png"], stderr_to_stdout: true) do
      {bytes, 0} when byte_size(bytes) > 0 ->
        {:ok, "image/png", bytes}

      _ ->
        case System.cmd(exec, ["-t", "image/jpeg"], stderr_to_stdout: true) do
          {bytes, 0} when byte_size(bytes) > 0 -> {:ok, "image/jpeg", bytes}
          _ -> {:error, "No image found on clipboard."}
        end
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp fetch_xclip_image(exec) do
    case System.cmd(exec, ["-selection", "clipboard", "-t", "image/png", "-o"],
           stderr_to_stdout: true
         ) do
      {bytes, 0} when byte_size(bytes) > 0 ->
        {:ok, "image/png", bytes}

      _ ->
        case System.cmd(exec, ["-selection", "clipboard", "-t", "image/jpeg", "-o"],
               stderr_to_stdout: true
             ) do
          {bytes, 0} when byte_size(bytes) > 0 -> {:ok, "image/jpeg", bytes}
          _ -> {:error, "No image found on clipboard."}
        end
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp fetch_pngpaste_image(exec) do
    case System.cmd(exec, ["-"], stderr_to_stdout: true) do
      {bytes, 0} when byte_size(bytes) > 0 -> {:ok, "image/png", bytes}
      _ -> {:error, "No image found on clipboard."}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp fetch_osascript_image(exec) do
    script =
      "try\n  set imgData to the clipboard as «class PNGf»\n  return imgData\non error\n  return \"\"\nend try"

    case System.cmd(exec, ["-e", script], stderr_to_stdout: true) do
      {bytes, 0} when byte_size(bytes) > 0 -> {:ok, "image/png", bytes}
      _ -> {:error, "No image found on clipboard."}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp fetch_powershell_image(exec) do
    cmd =
      "[Reflection.Assembly]::LoadWithPartialName('System.Drawing'); [System.Windows.Forms.Clipboard]::GetImage()"

    case System.cmd(exec, ["-command", cmd], stderr_to_stdout: true) do
      {bytes, 0} when byte_size(bytes) > 0 -> {:ok, "image/png", bytes}
      _ -> {:error, "No image found on clipboard."}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end
end
