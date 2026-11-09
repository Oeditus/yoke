defmodule Yoke.CLI.Doctor do
  @moduledoc """
  Runs read-only system diagnostic checks for Yoke.
  Verifies workspace permissions, Erlang/Elixir runtime versions, API provider keys,
  git repo status, and system tool dependencies.
  """

  alias Yoke.CLI.Formatter

  @native_features_selected Application.compile_env(:yoke, :embeddings_enabled, false)
  @native_apps [:bumblebee, :nx, :exla, :image]

  defstruct [:status, :checks, :summary]

  @doc "Runs all diagnostic checks and prints or returns a report."
  def run(workspace \\ File.cwd!(), opts \\ []) do
    checks = [
      check_runtime(),
      check_workspace(workspace),
      check_provider(workspace, opts),
      check_git(workspace),
      check_tools(),
      check_optional_features()
    ]

    all_ok? = Enum.all?(checks, fn %{status: status} -> status == :ok end)
    status = if all_ok?, do: :ok, else: :error

    %__MODULE__{
      status: status,
      checks: checks,
      summary: format_report(checks, status)
    }
  end

  @doc "Reports build-time optional features without loading applications, NIFs, or models."
  def check_optional_features do
    availability =
      Enum.map(@native_apps, fn app ->
        {app, :code.where_is_file(String.to_charlist("#{app}.app")) != :non_existing}
      end)

    optional_features_report(@native_features_selected, availability)
  end

  @doc false
  @spec optional_features_report(boolean(), [{atom(), boolean()}]) :: map()
  def optional_features_report(native_features_selected?, availability) do
    selected = if native_features_selected?, do: "enabled", else: "disabled"

    %{
      category: "Optional Native Features",
      status:
        if(native_features_selected? and not Enum.all?(availability, &elem(&1, 1)),
          do: :warning,
          else: :ok
        ),
      details:
        "Compiled embeddings/image selection: #{selected}. " <>
          Enum.map_join(availability, ", ", fn {app, present?} ->
            "#{app}: #{if present?, do: "present", else: "absent"}"
          end) <>
          ". Availability checks metadata only; NIFs and models are not loaded or probed."
    }
  end

  def print_report(workspace \\ File.cwd!(), opts \\ []) do
    report = run(workspace, opts)
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

  defp check_provider(workspace, opts) do
    resolved = Yoke.Provider.resolve(Keyword.put(opts, :cwd, workspace))

    if resolved[:provider] do
      local? = Yoke.Provider.location(resolved[:endpoint]) == "LOCAL"
      configured? = is_binary(resolved[:api_key]) and resolved[:api_key] != ""

      %{
        category: "AI Provider Credentials",
        status: if(local? or configured?, do: :ok, else: :warning),
        details:
          Yoke.Provider.describe(resolved) <>
            if(local?,
              do: " (no API key required)",
              else: " (credentials configured: #{configured?})"
            )
      }
    else
      check_provider()
    end
  rescue
    error in ArgumentError ->
      %{category: "AI Provider Credentials", status: :error, details: Exception.message(error)}
  end

  defp check_provider do
    yoke_key = System.get_env("YOKE_API_KEY")
    openai_key = System.get_env("OPENAI_API_KEY")
    llm_key = System.get_env("LLM_API_KEY")
    deepseek_key = System.get_env("DEEPSEEK_API_KEY")
    openrouter_key = System.get_env("OPENROUTER_API_KEY")
    opencode_key = System.get_env("OPENCODE_API_KEY") || System.get_env("OPENCODE_ZEN_API_KEY")

    provider_endpoint =
      System.get_env("YOKE_ENDPOINT") ||
        System.get_env("OPENAI_BASE_URL") ||
        System.get_env("DEEPSEEK_ENDPOINT") ||
        System.get_env("OPENCODE_BASE_URL") ||
        "https://api.deepseek.com"

    cond do
      is_binary(yoke_key) and byte_size(yoke_key) > 0 ->
        %{
          category: "AI Provider Credentials",
          status: :ok,
          details: "YOKE_API_KEY detected (#{provider_endpoint})"
        }

      is_binary(openai_key) and byte_size(openai_key) > 0 ->
        %{
          category: "AI Provider Credentials",
          status: :ok,
          details: "OPENAI_API_KEY detected (#{provider_endpoint})"
        }

      is_binary(llm_key) and byte_size(llm_key) > 0 ->
        %{
          category: "AI Provider Credentials",
          status: :ok,
          details: "LLM_API_KEY detected (#{provider_endpoint})"
        }

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

      is_binary(opencode_key) and byte_size(opencode_key) > 0 ->
        %{
          category: "AI Provider Credentials",
          status: :ok,
          details: "OPENCODE_API_KEY detected (#{provider_endpoint})"
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
