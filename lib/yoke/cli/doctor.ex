defmodule Yoke.CLI.Doctor do
  @moduledoc """
  Runs read-only system diagnostic checks for Yoke.
  Verifies workspace permissions, Erlang/Elixir runtime versions, API provider keys,
  git repo status, and system tool dependencies.
  """

  alias Yoke.CLI.Formatter

  defstruct [:status, :checks, :summary]

  @doc "Runs all diagnostic checks and prints or returns a report."
  def run(workspace \\ File.cwd!()) do
    checks = [
      check_runtime(),
      check_workspace(workspace),
      check_provider(),
      check_git(workspace),
      check_tools()
    ]

    all_ok? = Enum.all?(checks, fn %{status: status} -> status == :ok end)
    status = if all_ok?, do: :ok, else: :error

    %__MODULE__{
      status: status,
      checks: checks,
      summary: format_report(checks, status)
    }
  end

  def print_report(workspace \\ File.cwd!()) do
    report = run(workspace)
    IO.puts(report.summary)
    report.status
  end

  defp check_runtime do
    elixir_ver = System.version()
    otp_ver = System.otp_release()

    %{
      category: "BEAM Runtime",
      status: :ok,
      details: "Elixir #{elixir_ver} | Erlang/OTP #{otp_ver}"
    }
  end

  defp check_workspace(workspace) do
    if File.dir?(workspace) do
      yoke_dir = Path.join(workspace, ".yoke")
      File.mkdir_p!(yoke_dir)

      test_file = Path.join(yoke_dir, ".doctor_test")

      case File.write(test_file, "ok") do
        :ok ->
          File.rm(test_file)

          %{
            category: "Workspace Permissions",
            status: :ok,
            details: "Writable root (#{workspace})"
          }

        {:error, reason} ->
          %{
            category: "Workspace Permissions",
            status: :error,
            details: "Cannot write to .yoke directory: #{inspect(reason)}"
          }
      end
    else
      %{
        category: "Workspace Confinement",
        status: :error,
        details: "Directory '#{workspace}' does not exist"
      }
    end
  end

  defp check_provider do
    deepseek_key = System.get_env("DEEPSEEK_API_KEY")
    openrouter_key = System.get_env("OPENROUTER_API_KEY")
    provider_endpoint = System.get_env("DEEPSEEK_ENDPOINT") || "https://api.deepseek.com"

    cond do
      is_binary(deepseek_key) and byte_size(deepseek_key) > 0 ->
        %{
          category: "AI Provider Credentials",
          status: :ok,
          details: "DEEPSEEK_API_KEY detected (#{provider_endpoint})"
        }

      is_binary(openrouter_key) and byte_size(openrouter_key) > 0 ->
        %{
          category: "AI Provider Credentials",
          status: :ok,
          details: "OPENROUTER_API_KEY detected"
        }

      true ->
        %{
          category: "AI Provider Credentials",
          status: :warning,
          details: "No remote API key set (local/mock mode active)"
        }
    end
  end

  defp check_git(workspace) do
    case System.cmd("git", ["rev-parse", "--show-toplevel"],
           cd: workspace,
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        git_root = String.trim(output)

        %{
          category: "Git Repository",
          status: :ok,
          details: "Git repository detected at #{git_root}"
        }

      _ ->
        %{
          category: "Git Repository",
          status: :warning,
          details: "Not inside a git repository"
        }
    end
  end

  defp check_tools do
    git? = System.find_executable("git") != nil
    mix? = System.find_executable("mix") != nil

    if git? and mix? do
      %{
        category: "System Tools",
        status: :ok,
        details: "git and mix executable binaries available in PATH"
      }
    else
      %{
        category: "System Tools",
        status: :error,
        details: "Missing required tools: git: #{git?}, mix: #{mix?}"
      }
    end
  end

  defp format_report(checks, aggregate_status) do
    header =
      Formatter.bold() <>
        Formatter.cyan() <>
        "🩺 Yoke Health & Environment Doctor" <>
        Formatter.reset() <>
        "\n" <>
        String.duplicate("─", 50) <> "\n"

    items =
      Enum.map_join(checks, "\n", fn check ->
        icon =
          case check.status do
            :ok -> Formatter.green() <> "✔ " <> Formatter.reset()
            :warning -> Formatter.yellow() <> "▲ " <> Formatter.reset()
            :error -> Formatter.red() <> "✖ " <> Formatter.reset()
          end

        icon <>
          Formatter.bold() <>
          check.category <> Formatter.reset() <> "\n  └─ " <> check.details
      end)

    footer =
      "\n" <>
        String.duplicate("─", 50) <>
        "\n" <>
        case aggregate_status do
          :ok ->
            Formatter.green() <> "Status: All checks passed cleanly." <> Formatter.reset()

          _ ->
            Formatter.yellow() <>
              "Status: Some checks issued warnings or errors." <> Formatter.reset()
        end

    header <> items <> footer
  end
end
