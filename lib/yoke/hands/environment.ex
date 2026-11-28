defmodule Yoke.Hands.Environment do
  @moduledoc """
  Builds scrubbed environment variables for subprocess execution.
  Only explicitly allowlisted toolchain locations and controlled defaults are inherited.
  Other inherited variables (including API keys) are set to `nil`, which unsets them
  in `System.cmd`. Trusted callers may explicitly override or unset variables.

  The real user home is preserved independently of the workspace. This is environment
  sanitization, not a filesystem sandbox: tools can still read user configuration.
  """

  @default_path "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin"
  @inherited_paths ~w(MIX_HOME HEX_HOME MIX_ARCHIVES ERL_HOME)
  @erts_env_vars ~w(ROOTDIR BINDIR EMU PROGNAME)

  @type entry :: {String.t(), String.t() | nil}
  @doc "Resolves the parent user home independently of the execution workspace."
  @spec user_home(map()) :: String.t()
  def user_home(parent_env \\ System.get_env()) do
    Map.get(parent_env, "HOME") || System.user_home!()
  end

  @doc """
  Returns `PATH` stripped of Erlang/OTP `erlexec` and Mix release bin entries
  injected when Yoke's BEAM started.

  If `YOKE_ORIG_PATH` was captured by the `yoke` launcher before `exec`ing into
  the OTP release, that original `PATH` is returned verbatim. Otherwise, `BINDIR`
  (the embedded `erts-<vsn>/bin`) and, when running inside a Mix release
  (`RELEASE_ROOT` is set), any entry under `RELEASE_ROOT` or `ROOTDIR/bin` are
  removed.
  """
  @spec clean_path(map()) :: String.t()
  def clean_path(parent_env \\ System.get_env()) do
    case Map.get(parent_env, "YOKE_ORIG_PATH") do
      orig when is_binary(orig) and orig != "" ->
        orig

      _ ->
        raw_path = Map.get(parent_env, "PATH") || @default_path
        strip_erts_path_entries(raw_path, parent_env)
    end
  end

  @doc """
  Sanitizes the current BEAM process's OS environment after boot.

  When Yoke runs as an OTP release (or escript), the release launcher and
  `erlexec` export `RELEASE_*`, `ROOTDIR`, `BINDIR`, `EMU`, and `PROGNAME`, and
  prepend the embedded `erts-<vsn>/bin` and `<release>/bin` directories to
  `PATH`. Leaving those in the BEAM's environment causes child `mix`, `elixir`,
  and `erl` invocations (such as `/linter credo` or shell tools) to execute
  Yoke's embedded ERTS with Yoke's `ROOTDIR` instead of the project's Erlang
  toolchain.

  The running BEAM VM retains its own `:code.root_dir/0` internally, so
  cleaning these OS environment variables after boot is safe and idempotent.
  """
  @spec sanitize_runtime_env() :: :ok
  def sanitize_runtime_env do
    parent_env = System.get_env()
    cleaned_path = clean_path(parent_env)

    if cleaned_path != Map.get(parent_env, "PATH") do
      System.put_env("PATH", cleaned_path)
    end

    System.delete_env("YOKE_ORIG_PATH")
    Enum.each(@erts_env_vars, &System.delete_env/1)

    case Map.get(parent_env, "RELEASE_ROOT") do
      release_root when is_binary(release_root) and release_root != "" ->
        if Map.get(parent_env, "ERL_ROOTDIR") == release_root do
          System.delete_env("ERL_ROOTDIR")
        end

        # Inside an assembled OTP release, MIX_ENV is meaningless for Yoke
        # itself and breaks dev/test-only Mix tools (credo, prisma, dialyzer,
        # oeditus_credo, propwise) when Yoke shells out to `mix` on the
        # underlying project if the caller had MIX_ENV=prod set.
        System.delete_env("MIX_ENV")

        parent_env
        |> Map.keys()
        |> Enum.filter(&String.starts_with?(&1, "RELEASE_"))
        |> Enum.each(&System.delete_env/1)

      _ ->
        :ok
    end

    :ok
  end

  @doc "Builds scrubbed environment list for System.cmd or :erlang.open_port."
  @spec build(String.t(), map() | keyword()) :: [entry()]
  def build(_workspace \\ File.cwd!(), extra_env \\ %{}) do
    parent_env = System.get_env()
    path = clean_path(parent_env)
    tmpdir = System.tmp_dir!()

    current_env_keys =
      parent_env
      |> Map.keys()
      |> Map.new(&{&1, nil})

    controlled_env = %{
      "GIT_CONFIG_GLOBAL" => "/dev/null",
      "GIT_CONFIG_NOSYSTEM" => "1",
      "GIT_TERMINAL_PROMPT" => "0",
      "HOME" => user_home(parent_env),
      "LANG" => "C.UTF-8",
      "LC_ALL" => "C.UTF-8",
      "NO_COLOR" => "1",
      "PATH" => path,
      "TMPDIR" => tmpdir
    }

    extra_entries =
      cond do
        is_map(extra_env) -> extra_env
        is_list(extra_env) -> extra_env
        true -> []
      end

    extra =
      Map.new(extra_entries, fn
        {k, v} when v in [nil, false] -> {to_string(k), nil}
        {k, v} -> {to_string(k), to_string(v)}
      end)

    current_env_keys
    |> Map.merge(Map.take(parent_env, @inherited_paths))
    |> Map.merge(controlled_env)
    |> Map.merge(extra)
    |> Enum.to_list()
  end

  defp strip_erts_path_entries(raw_path, parent_env) do
    bindir = normalize_dir(Map.get(parent_env, "BINDIR"))
    rootdir = normalize_dir(Map.get(parent_env, "ROOTDIR"))
    release_root = normalize_dir(Map.get(parent_env, "RELEASE_ROOT"))

    exact_strip =
      [
        bindir,
        if(release_root, do: Path.join(release_root, "bin")),
        if(release_root && rootdir, do: Path.join(rootdir, "bin"))
      ]
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    release_prefix = if release_root, do: release_root <> "/", else: nil

    cleaned =
      raw_path
      |> String.split(":", trim: true)
      |> Enum.reject(fn entry ->
        norm = normalize_dir(entry)

        MapSet.member?(exact_strip, norm) or
          (release_root != nil and
             (norm == release_root or String.starts_with?(norm || "", release_prefix)))
      end)
      |> Enum.join(":")

    if cleaned == "", do: @default_path, else: cleaned
  end

  defp normalize_dir(nil), do: nil
  defp normalize_dir(""), do: nil
  defp normalize_dir("/"), do: "/"
  defp normalize_dir(dir) when is_binary(dir), do: String.trim_trailing(dir, "/")
end
