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

  @type entry :: {String.t(), String.t() | nil}
  @doc "Resolves the parent user home independently of the execution workspace."
  @spec user_home(map()) :: String.t()
  def user_home(parent_env \\ System.get_env()) do
    Map.get(parent_env, "HOME") || System.user_home!()
  end

  @doc "Builds scrubbed environment list for System.cmd or :erlang.open_port."
  @spec build(String.t(), map() | keyword()) :: [entry()]
  def build(_workspace \\ File.cwd!(), extra_env \\ %{}) do
    parent_env = System.get_env()
    path = Map.get(parent_env, "PATH", @default_path)
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
end
