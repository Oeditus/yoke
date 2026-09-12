defmodule Yoke.Workspace.Path.Lexical do
  @moduledoc """
  Lexically validates and resolves a relative path against a workspace root without hitting the filesystem.
  Rejects empty paths, parent traversals (..), drive letters, backslashes, and null bytes.
  """

  @doc "Resolves relative path against workspace lexically."
  @spec resolve(String.t(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def resolve(workspace, path) when is_binary(workspace) and is_binary(path) do
    with :ok <- validate_path_string(path),
         {:ok, normalized_path} <- normalize_relative(path) do
      expanded = Path.expand(normalized_path, workspace)
      {:ok, expanded}
    end
  end

  def resolve(_workspace, _path) do
    {:error, "invalid path"}
  end

  defp validate_path_string(path) do
    cond do
      byte_size(path) == 0 ->
        {:error, "path cannot be empty"}

      :binary.match(path, <<0>>) != :nomatch ->
        {:error, "path contains null byte"}

      String.contains?(path, "\\") ->
        {:error, "path contains backslash separators"}

      Regex.match?(~r/^[a-zA-Z]:/, path) ->
        {:error, "windows drive letter paths not permitted"}

      true ->
        :ok
    end
  end

  defp normalize_relative(path) do
    components = Path.split(path)

    if Enum.any?(components, &(&1 == "..")) do
      {:error, "path contains parent traversal (..)"}
    else
      {:ok, path}
    end
  end
end
