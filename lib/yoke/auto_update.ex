defmodule Yoke.AutoUpdate do
  @moduledoc """
  Auto-update system for Yoke (`yoke`).

  Periodically checks GitHub Releases for newer releases upon start.
  When a newer version is found, prompts the user interactively and installs
  the update if accepted.
  """

  @default_interval 86_400
  @default_repo "Oeditus/yoke"
  @default_api_base "https://api.github.com"

  @doc """
  Checks for updates from GitHub Releases if due, prompts the user if a newer version
  is found, and installs it if accepted.

  Returns `{:ok, :installed, version}`, `{:ok, :declined}`, `{:ok, :up_to_date}`,
  `{:ok, :skipped}`, or `{:error, reason}`.
  """
  @spec maybe_check_and_prompt(keyword()) ::
          {:ok, :installed, String.t()}
          | {:ok, :declined}
          | {:ok, :up_to_date}
          | {:ok, :skipped}
          | {:error, term()}
  def maybe_check_and_prompt(opts \\ []) do
    if should_check?(opts) do
      case check_for_updates(opts) do
        {:newer_version, latest_version, release_data} ->
          current_version = Keyword.get(opts, :current_version) || Yoke.version()

          if prompt_install(latest_version, current_version, opts) do
            IO.puts(Yoke.CLI.Formatter.format_info("Installing Yoke v#{latest_version}…"))

            case install_update(release_data, opts) do
              {:ok, target_path} ->
                IO.puts(
                  Yoke.CLI.Formatter.format_success(
                    "Yoke has been successfully updated to v#{latest_version}! (#{target_path})"
                  )
                )

                IO.puts(
                  Yoke.CLI.Formatter.format_info(
                    "The update will take effect on your next run (or restart Yoke to use it now).\n"
                  )
                )

                {:ok, :installed, latest_version}

              {:error, reason} ->
                IO.puts(Yoke.CLI.Formatter.format_error("Failed to install update: #{reason}"))
                {:error, reason}
            end
          else
            IO.puts(
              Yoke.CLI.Formatter.format_info(
                "Update skipped. You can update anytime with '/update' or 'yoke update'.\n"
              )
            )

            {:ok, :declined}
          end

        {:up_to_date, _ver} ->
          {:ok, :up_to_date}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:ok, :skipped}
    end
  rescue
    e ->
      {:error, Exception.message(e)}
  end

  @doc "Checks for updates immediately (ignoring interval) and prompts/installs if available."
  @spec manual_update(keyword()) :: non_neg_integer()
  def manual_update(opts \\ []) do
    IO.puts(Yoke.CLI.Formatter.format_info("Checking for Yoke updates from GitHub…"))
    opts = Keyword.put(opts, :force, true)

    case check_for_updates(opts) do
      {:newer_version, latest_version, release_data} ->
        current_version = Keyword.get(opts, :current_version) || Yoke.version()

        if prompt_install(latest_version, current_version, opts) do
          IO.puts(Yoke.CLI.Formatter.format_info("Installing Yoke v#{latest_version}…"))

          case install_update(release_data, opts) do
            {:ok, target_path} ->
              IO.puts(
                Yoke.CLI.Formatter.format_success(
                  "Yoke has been successfully updated to v#{latest_version}! (#{target_path})"
                )
              )

              0

            {:error, reason} ->
              IO.puts(Yoke.CLI.Formatter.format_error("Failed to install update: #{reason}"))
              1
          end
        else
          IO.puts(Yoke.CLI.Formatter.format_info("Update cancelled."))
          0
        end

      {:up_to_date, ver} ->
        IO.puts(Yoke.CLI.Formatter.format_success("Yoke is already up to date (v#{ver})."))
        0

      {:error, reason} ->
        IO.puts(
          Yoke.CLI.Formatter.format_error("Could not check for updates: #{inspect(reason)}")
        )

        1
    end
  rescue
    e ->
      IO.puts(
        Yoke.CLI.Formatter.format_error("Could not check for updates: #{Exception.message(e)}")
      )

      1
  end

  @doc "Entry point for `yoke update` subcommand."
  @spec cli_update([String.t()]) :: non_neg_integer()
  def cli_update(_args) do
    manual_update()
  end

  @doc """
  Determines if an update check should be performed.

  The auto-update feature is ON if and only if `yoke` is running as a published
  release, and not from the sources.
  """
  @spec should_check?(keyword()) :: boolean()
  def should_check?(opts \\ []) do
    cond do
      Keyword.get(opts, :force, false) ->
        true

      not published_release?(opts) ->
        false

      System.get_env("YOKE_NO_AUTO_UPDATE") in ["1", "true"] ->
        false

      System.get_env("YOKE_DISABLE_AUTO_UPDATE") in ["1", "true"] ->
        false

      ci_environment?(opts) ->
        false

      not interactive?(opts) ->
        false

      true ->
        config = Yoke.Config.load_config()

        if Map.get(config, "auto_update", true) == false do
          false
        else
          interval =
            Keyword.get(opts, :interval) ||
              parse_interval(System.get_env("YOKE_UPDATE_CHECK_INTERVAL")) ||
              Map.get(config, "update_check_interval", @default_interval)

          now = System.system_time(:second)
          state = read_state(opts)
          last_check = Map.get(state, "last_check_at", 0)

          now - last_check >= interval
        end
    end
  end

  @doc """
  Returns true if yoke is running as a published release, and not from the sources.
  """
  @spec published_release?(keyword()) :: boolean()
  def published_release?(opts \\ []) do
    case Keyword.fetch(opts, :published_release) do
      {:ok, val} when is_boolean(val) ->
        val

      :error ->
        case System.get_env("YOKE_AUTO_UPDATE_RELEASE") do
          val when val in ["1", "true"] ->
            true

          val when val in ["0", "false"] ->
            false

          _ ->
            running_as_release?(opts) and not running_from_source?(opts)
        end
    end
  end

  @doc "Returns true if running as an escript / standalone binary."
  @spec running_as_release?(keyword()) :: boolean()
  def running_as_release?(opts \\ []) do
    case Keyword.fetch(opts, :is_release) do
      {:ok, val} when is_boolean(val) ->
        val

      :error ->
        escript?()
    end
  end

  @doc "Returns true if yoke is running from source files or a source git checkout."
  @spec running_from_source?(keyword()) :: boolean()
  def running_from_source?(opts \\ []) do
    case Keyword.fetch(opts, :from_source) do
      {:ok, val} when is_boolean(val) ->
        val

      :error ->
        cond do
          # Running via mix (mix run, iex -S mix, mix test)
          Code.ensure_loaded?(Mix) and function_exported?(Mix, :env, 0) and Mix.env() != :escript ->
            true

          # YOKE_REPO_DIR points to a Yoke source repository
          repo = System.get_env("YOKE_REPO_DIR") ->
            yoke_source_repo?(repo)

          # Current working directory is inside a Yoke source repository
          find_yoke_source_repo(File.cwd!()) != nil ->
            true

          # The running executable is located inside a Yoke source repository
          exec_path = escript_target_path() ->
            find_yoke_source_repo(Path.dirname(exec_path)) != nil

          true ->
            false
        end
    end
  end

  @doc "Searches up from the given directory to find a Yoke source repository root."
  @spec find_yoke_source_repo(String.t() | nil) :: String.t() | nil
  def find_yoke_source_repo(nil), do: nil

  def find_yoke_source_repo(dir) when is_binary(dir) do
    dir = Path.expand(dir)
    do_find_yoke_source_repo(dir)
  end

  defp do_find_yoke_source_repo(dir) do
    cond do
      yoke_source_repo?(dir) ->
        dir

      dir in ["/", "."] or Path.dirname(dir) == dir ->
        nil

      true ->
        do_find_yoke_source_repo(Path.dirname(dir))
    end
  end

  @doc "Returns true if the current process is running as an escript archive."
  @spec escript?() :: boolean()
  def escript? do
    case :escript.script_name() do
      [] -> false
      [?-, ?e] -> false
      name when is_list(name) -> true
    end
  end

  @doc "Queries GitHub Releases API for the latest release."
  @spec check_for_updates(keyword()) ::
          {:newer_version, String.t(), map()}
          | {:up_to_date, String.t()}
          | {:error, term()}
  def check_for_updates(opts \\ []) do
    repo = Keyword.get(opts, :repo) || System.get_env("YOKE_GITHUB_REPO") || @default_repo

    api_base =
      Keyword.get(opts, :api_base) || System.get_env("YOKE_GITHUB_API_URL") || @default_api_base

    current_version = Keyword.get(opts, :current_version) || Yoke.version()

    url = "#{api_base}/repos/#{repo}/releases/latest"

    headers = [
      {"accept", "application/vnd.github.v3+json"},
      {"user-agent", "Yoke-CLI/#{current_version}"}
    ]

    headers =
      case System.get_env("GITHUB_TOKEN") do
        tok when is_binary(tok) and tok != "" -> [{"authorization", "Bearer #{tok}"} | headers]
        _ -> headers
      end

    timeout = Keyword.get(opts, :timeout, 4_000)

    # Record check time so subsequent starts don't re-query
    record_check_time(opts)

    req_opts = [
      headers: headers,
      receive_timeout: timeout,
      retry: Keyword.get(opts, :retry, false)
    ]

    req_opts =
      case Keyword.get(opts, :plug) do
        nil -> req_opts
        plug -> Keyword.put(req_opts, :plug, plug)
      end

    case Req.get(url, req_opts) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        data = parse_response_body(body)
        tag_name = Map.get(data, "tag_name", "")

        case compare_versions(tag_name, current_version) do
          :newer ->
            latest_ver = String.trim_leading(tag_name, "v")
            {:newer_version, latest_ver, data}

          :up_to_date ->
            {:up_to_date, String.trim_leading(tag_name, "v")}

          :older ->
            {:up_to_date, current_version}

          :error ->
            {:error, :unparseable_version}
        end

      {:ok, %Req.Response{status: status}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e ->
      {:error, Exception.message(e)}
  end

  @doc "Compares release tag with current version using SemVer."
  @spec compare_versions(String.t(), String.t()) :: :newer | :up_to_date | :older | :error
  def compare_versions(tag_name, current_version) do
    clean_tag = String.trim_leading(to_string(tag_name), "v")
    clean_curr = String.trim_leading(to_string(current_version), "v")

    with {:ok, tag_ver} <- Version.parse(clean_tag),
         {:ok, curr_ver} <- Version.parse(clean_curr) do
      case Version.compare(tag_ver, curr_ver) do
        :gt -> :newer
        :lt -> :older
        :eq -> :up_to_date
      end
    else
      _ -> :error
    end
  end

  @doc "Prompts the user whether to install the available update."
  @spec prompt_install(String.t(), String.t(), keyword()) :: boolean()
  def prompt_install(latest_version, current_version, opts \\ []) do
    prompt_fn = Keyword.get(opts, :prompt_fn)

    cond do
      is_function(prompt_fn, 2) ->
        case prompt_fn.(latest_version, current_version) do
          true -> true
          false -> false
          %{selected: [sel]} -> String.starts_with?(sel, "Yes")
          _ -> false
        end

      Keyword.get(opts, :god_mode, Yoke.Config.god_mode?()) ->
        IO.puts(
          Yoke.CLI.Formatter.format_info(
            "[God Mode] Automatically approving update to v#{latest_version}."
          )
        )

        true

      true ->
        question =
          "A new version of Yoke is available: v#{latest_version} (current: v#{current_version}). Would you like to install it?"

        options = ["Yes, install update", "No, skip for now"]

        ans =
          Yoke.CLI.QuestionPrompt.ask_single_question(
            question,
            options,
            false,
            true,
            filterable: true
          )

        case ans do
          %{selected: [selected]} when is_binary(selected) ->
            String.starts_with?(selected, "Yes")

          %{custom: custom} when is_binary(custom) ->
            String.starts_with?(custom, "Yes") or String.downcase(custom) in ["y", "yes"]

          _ ->
            false
        end
    end
  end

  @doc "Installs the update from GitHub release or git repository."
  @spec install_update(map(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def install_update(release_data, opts \\ []) do
    repo_dir =
      Keyword.get(opts, :repo_dir) ||
        System.get_env("YOKE_REPO_DIR") ||
        Application.get_env(:yoke, :repo_dir)

    if yoke_source_repo?(repo_dir) and not Keyword.get(opts, :force_binary, false) do
      install_from_source(repo_dir)
    else
      install_from_release(release_data, opts)
    end
  end

  @doc "Downloads and installs the prebuilt binary from GitHub Release assets."
  @spec install_from_release(map(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def install_from_release(release_data, opts \\ []) do
    assets = Map.get(release_data, "assets", [])
    yoke_asset = Enum.find(assets, fn a -> Map.get(a, "name") == "yoke" end)

    sha_asset =
      Enum.find(assets, fn a -> Map.get(a, "name") in ["yoke.sha256", "yoke.sha256sum"] end)

    if yoke_asset == nil do
      {:error, "No 'yoke' binary asset found in release."}
    else
      download_url = Map.get(yoke_asset, "browser_download_url")
      target_path = resolve_target_path(opts)

      with {:ok, binary_content} <- download_binary(download_url, opts),
           :ok <- maybe_verify_checksum(binary_content, sha_asset, opts) do
        install_binary(binary_content, target_path)
      end
    end
  end

  @doc "Writes binary content atomically to target_path and sets executable permissions."
  @spec install_binary(binary(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def install_binary(binary_content, target_path)
      when is_binary(binary_content) and is_binary(target_path) do
    target_path = Path.expand(target_path)
    target_dir = Path.dirname(target_path)

    case File.mkdir_p(target_dir) do
      :ok ->
        temp_path = Path.join(target_dir, ".yoke_update_#{System.unique_integer([:positive])}")

        try do
          File.write!(temp_path, binary_content)
          File.chmod!(temp_path, 0o755)
          File.rename(temp_path, target_path)
          {:ok, target_path}
        rescue
          e in [File.Error, ErlangError] ->
            File.rm(temp_path)
            {:error, "Failed to write binary to #{target_path}: #{Exception.message(e)}"}
        after
          File.rm(temp_path)
        end

      {:error, reason} ->
        {:error, "Failed to create directory #{target_dir}: #{inspect(reason)}"}
    end
  end

  @doc "Verifies SHA256 checksum of binary content against expected SHA text."
  @spec verify_checksum(binary(), binary()) :: :ok | {:error, String.t()}
  def verify_checksum(binary_content, sha_text)
      when is_binary(binary_content) and is_binary(sha_text) do
    expected_hash =
      sha_text
      |> String.trim()
      |> String.split(~r/\s+/)
      |> List.first()
      |> to_string()
      |> String.downcase()

    actual_hash =
      :crypto.hash(:sha256, binary_content)
      |> Base.encode16(case: :lower)

    if expected_hash == actual_hash do
      :ok
    else
      {:error,
       "Checksum verification failed: expected #{expected_hash}, calculated #{actual_hash}"}
    end
  end

  @doc "Resolves the target path where the yoke executable should be installed."
  @spec resolve_target_path(keyword()) :: String.t()
  def resolve_target_path(opts \\ []) do
    cond do
      path = Keyword.get(opts, :target_path) ->
        Path.expand(path)

      env_path = System.get_env("YOKE_INSTALL_PATH") ->
        Path.expand(env_path)

      escript_path = escript_target_path() ->
        escript_path

      exec_path = System.find_executable("yoke") ->
        Path.expand(exec_path)

      true ->
        Path.expand("~/.local/bin/yoke")
    end
  end

  @doc "Returns true if the directory is a Yoke source repository checkout."
  @spec yoke_source_repo?(String.t() | nil) :: boolean()
  def yoke_source_repo?(repo_dir) do
    is_binary(repo_dir) and
      File.exists?(Path.join(repo_dir, ".git")) and
      File.exists?(Path.join(repo_dir, "mix.exs")) and
      case File.read(Path.join(repo_dir, "mix.exs")) do
        {:ok, content} -> String.contains?(content, "defmodule Yoke.MixProject")
        _ -> false
      end
  end

  @doc "Returns the path to the state persistence file."
  @spec state_file_path(keyword()) :: String.t()
  def state_file_path(opts \\ []) do
    Keyword.get(opts, :state_file) ||
      System.get_env("YOKE_UPDATE_STATE_FILE") ||
      Path.expand("~/.yoke/update_check.json")
  end

  @doc "Reads the update state JSON file."
  @spec read_state(keyword()) :: map()
  def read_state(opts \\ []) do
    path = state_file_path(opts)

    case File.read(path) do
      {:ok, content} ->
        case Yoke.Json.decode(content) do
          {:ok, map} when is_map(map) -> map
          _ -> %{}
        end

      _ ->
        %{}
    end
  end

  @doc "Writes the update state JSON file."
  @spec write_state(map(), keyword()) :: :ok
  def write_state(data, opts \\ []) when is_map(data) do
    path = state_file_path(opts)
    File.mkdir_p!(Path.dirname(path))

    case Yoke.Json.encode(data, pretty: true) do
      {:ok, json} ->
        File.write(path, json)
        :ok

      _ ->
        :ok
    end
  rescue
    _ -> :ok
  end

  @doc "Records the current timestamp as the last update check time."
  def record_check_time(opts \\ []) do
    now = System.system_time(:second)
    state = read_state(opts)
    updated = Map.put(state, "last_check_at", now)
    write_state(updated, opts)
  end

  # ---- Private Helpers ------------------------------------------------------

  defp escript_target_path do
    with [_ | _] = name when name != [?-, ?e] <- :escript.script_name(),
         name = List.to_string(name),
         true <- File.exists?(name) do
      Path.expand(name)
    else
      _ -> nil
    end
  end

  defp ci_environment?(opts) do
    case Keyword.fetch(opts, :ci) do
      {:ok, val} when is_boolean(val) ->
        val

      :error ->
        System.get_env("CI") in ["true", "1"] or
          System.get_env("GITHUB_ACTIONS") in ["true", "1"] or
          System.get_env("CONTINUOUS_INTEGRATION") in ["true", "1"]
    end
  end

  defp interactive?(opts) do
    Keyword.get(opts, :interactive, Yoke.CLI.Output.tty?())
  end

  @doc "Parses interval string or integer in seconds."
  @spec parse_interval(term()) :: non_neg_integer() | nil
  def parse_interval(val) when is_integer(val) and val >= 0, do: val

  def parse_interval(val) when is_binary(val) do
    case Integer.parse(val) do
      {int, ""} when int >= 0 -> int
      _ -> nil
    end
  end

  def parse_interval(_), do: nil

  defp parse_response_body(body) when is_map(body), do: body

  defp parse_response_body(body) when is_binary(body) do
    case Yoke.Json.decode(body) do
      {:ok, data} when is_map(data) -> data
      _ -> %{}
    end
  end

  defp parse_response_body(_), do: %{}

  defp download_binary(url, opts) do
    timeout = Keyword.get(opts, :download_timeout, 60_000)

    headers = [
      {"user-agent", "Yoke-CLI/#{Yoke.version()}"}
    ]

    headers =
      case System.get_env("GITHUB_TOKEN") do
        tok when is_binary(tok) and tok != "" -> [{"authorization", "Bearer #{tok}"} | headers]
        _ -> headers
      end

    req_opts = [
      headers: headers,
      receive_timeout: timeout,
      retry: Keyword.get(opts, :retry, false)
    ]

    req_opts =
      case Keyword.get(opts, :plug) do
        nil -> req_opts
        plug -> Keyword.put(req_opts, :plug, plug)
      end

    case Req.get(url, req_opts) do
      {:ok, %Req.Response{status: 200, body: content}} when is_binary(content) ->
        {:ok, content}

      {:ok, %Req.Response{status: status}} ->
        {:error, "Download failed with HTTP status #{status}"}

      {:error, reason} ->
        {:error, "Download error: #{inspect(reason)}"}
    end
  end

  defp maybe_verify_checksum(binary_content, sha_asset, opts) do
    if sha_asset && Map.get(sha_asset, "browser_download_url") do
      sha_url = Map.get(sha_asset, "browser_download_url")

      case download_binary(sha_url, opts) do
        {:ok, sha_text} ->
          verify_checksum(binary_content, sha_text)

        _ ->
          # If fetching SHA fails, proceed without blocking
          :ok
      end
    else
      :ok
    end
  end

  defp install_from_source(repo_dir) do
    IO.puts(
      Yoke.CLI.Formatter.format_info(
        "Pulling latest git changes and refreshing production release…"
      )
    )

    with 0 <- update_step("git", ["pull", "--rebase"], repo_dir, []),
         0 <- update_step("mix", ["release", "--overwrite"], repo_dir, [{"MIX_ENV", "prod"}]) do
      {:ok, repo_dir}
    else
      code -> {:error, "Build failed with exit code #{code}"}
    end
  end

  defp update_step(executable, args, repo_dir, env) do
    IO.puts(Yoke.CLI.Formatter.format_info("Running #{executable} #{Enum.join(args, " ")}"))

    {_, status} =
      System.cmd(executable, args,
        cd: repo_dir,
        env: env,
        stderr_to_stdout: true,
        into: IO.stream(:stdio, :line)
      )

    if status != 0 do
      IO.puts(
        Yoke.CLI.Formatter.format_error(
          "Update failed: #{executable} exited with status #{status}. See output above."
        )
      )
    end

    status
  rescue
    error in [ErlangError, File.Error] ->
      IO.puts(
        Yoke.CLI.Formatter.format_error(
          "Update failed: could not run #{executable}: #{Exception.message(error)}"
        )
      )

      127
  end
end
