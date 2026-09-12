defmodule Yoke.Hands.Environment do
  @moduledoc """
  Builds scrubbed environment variables for subprocess execution.
  Inherited process environment variables (like API keys or secrets) are set to `nil`
  (which unsets them in `System.cmd`), while a strictly controlled execution environment is injected.
  """

  @default_path "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin"

  @type entry :: {String.t(), String.t() | nil}

  @doc "Builds scrubbed environment list for System.cmd or :erlang.open_port."
  @spec build(String.t(), map() | keyword()) :: [entry()]
  def build(workspace \\ File.cwd!(), extra_env \\ %{}) do
    path = System.get_env("PATH", @default_path)
    tmpdir = System.tmp_dir!()

    current_env_keys =
      System.get_env()
      |> Map.keys()
      |> Map.new(&{&1, nil})

    controlled_env = %{
      "GIT_CONFIG_GLOBAL" => "/dev/null",
      "GIT_CONFIG_NOSYSTEM" => "1",
      "GIT_TERMINAL_PROMPT" => "0",
      "HOME" => workspace,
      "LANG" => "C.UTF-8",
      "LC_ALL" => "C.UTF-8",
      "NO_COLOR" => "1",
      "PATH" => path,
      "TMPDIR" => tmpdir
    }

    extra =
      cond do
        is_map(extra_env) -> extra_env
        is_list(extra_env) -> Map.new(extra_env)
        true -> %{}
      end

    current_env_keys
    |> Map.merge(controlled_env)
    |> Map.merge(extra)
    |> Enum.map(fn
      {k, nil} -> {to_string(k), nil}
      {k, false} -> {to_string(k), nil}
      {k, v} -> {to_string(k), to_string(v)}
    end)
  end
end
