defmodule Yoke.Workspace.Path.Canonical do
  @moduledoc """
  Resolves existing components and symlinks on disk up to max depth.
  """

  @max_symlink_depth 10

  @doc "Resolves canonical target path on disk."
  @spec resolve(String.t(), :read | :write) :: {:ok, String.t()} | {:error, atom()}
  def resolve(path, access) when is_binary(path) and access in [:read, :write] do
    case access do
      :read ->
        resolve_existing(path, 0)

      :write ->
        if File.exists?(path) or symlink?(path) do
          resolve_existing(path, 0)
        else
          parent = Path.dirname(path)

          case resolve_existing(parent, 0) do
            {:ok, canonical_parent} ->
              {:ok, Path.join(canonical_parent, Path.basename(path))}

            error ->
              error
          end
        end
    end
  end

  def directory?(path) when is_binary(path) do
    File.dir?(path)
  end

  defp symlink?(path) do
    match?({:ok, %File.Stat{type: :symlink}}, File.lstat(path))
  end

  defp resolve_existing(_path, depth) when depth > @max_symlink_depth do
    {:error, :unresolvable}
  end

  defp resolve_existing(path, depth) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :symlink}} ->
        case File.read_link(path) do
          {:ok, target} ->
            target_path =
              if Path.type(target) == :absolute do
                target
              else
                Path.expand(target, Path.dirname(path))
              end

            resolve_existing(target_path, depth + 1)

          _ ->
            {:error, :unresolvable}
        end

      {:ok, _stat} ->
        {:ok, Path.expand(path)}

      {:error, :enoent} ->
        {:error, :not_found}

      {:error, _reason} ->
        {:error, :unresolvable}
    end
  end
end
