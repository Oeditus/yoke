defmodule Yoke.Workspace.Path.Boundary do
  @moduledoc """
  Compares absolute path components for workspace containment.
  """

  @doc "Returns whether a candidate is the root or a descendant of it."
  @spec within?(String.t(), String.t()) :: boolean()
  def within?(root, candidate) when is_binary(root) and is_binary(candidate) do
    if absolute_pair?(root, candidate) do
      root_components = components(root)
      candidate_components = components(candidate)

      Enum.take(candidate_components, length(root_components)) == root_components
    else
      false
    end
  end

  def within?(_root, _candidate), do: false

  defp absolute_pair?(root, candidate) do
    Path.type(root) == :absolute and Path.type(candidate) == :absolute
  end

  defp components(path) do
    path
    |> Path.expand()
    |> Path.split()
  end
end
