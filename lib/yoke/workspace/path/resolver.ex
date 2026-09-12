defmodule Yoke.Workspace.Path.Resolver do
  @moduledoc """
  Resolves paths through lexical, canonical, and boundary confinement checks.
  Ensures target paths strictly remain within the workspace root.
  """

  alias Yoke.Workspace.Path.Boundary
  alias Yoke.Workspace.Path.Canonical
  alias Yoke.Workspace.Path.Lexical

  @doc "Resolves a read or write path inside an existing workspace directory."
  @spec resolve(String.t(), String.t(), :read | :write) ::
          {:ok, String.t()} | {:error, String.t()}
  def resolve(workspace, path, access \\ :read)
      when is_binary(workspace) and access in [:read, :write] do
    with {:ok, canonical_root} <- workspace_root(workspace),
         {:ok, lexical_target} <- Lexical.resolve(canonical_root, path),
         {:ok, canonical_target} <- target(lexical_target, access),
         true <- Boundary.within?(canonical_root, canonical_target) do
      {:ok, canonical_target}
    else
      false ->
        {:error, "path resolves outside workspace"}

      {:error, reason} when is_binary(reason) ->
        {:error, reason}

      {:error, :not_found} ->
        {:error, "path does not exist"}

      {:error, :unresolvable} ->
        {:error, "path cannot be resolved safely"}
    end
  end

  defp workspace_root(workspace) do
    case Canonical.resolve(workspace, :read) do
      {:ok, canonical} ->
        if Canonical.directory?(canonical) do
          {:ok, canonical}
        else
          {:error, "workspace must be an existing directory"}
        end

      _ ->
        {:error, "workspace directory does not exist or is unresolvable"}
    end
  end

  defp target(path, access) do
    Canonical.resolve(path, access)
  end
end
