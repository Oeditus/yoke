defmodule Yoke.StalenessTracker do
  @moduledoc """
  Fingerprint-based staleness tracker for Yoke.

  Computes SHA-256 content fingerprints of files, codebases, SCIP indexes, and context snapshots.
  Tracks fingerprints in `.yoke/fingerprints.json` to detect when underlying resources have changed
  and invalidate stale cached artifacts.
  """

  @store_file ".yoke/fingerprints.json"

  @doc "Computes SHA-256 hex fingerprint for binary data or a list of file paths."
  def compute_fingerprint(data) when is_binary(data) do
    :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)
  end

  def compute_fingerprint(file_paths) when is_list(file_paths) do
    hashes =
      file_paths
      |> Enum.sort()
      |> Enum.map(fn path ->
        if File.exists?(path) and not File.dir?(path) do
          case File.read(path) do
            {:ok, bytes} -> :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
            _ -> "missing"
          end
        else
          "missing"
        end
      end)

    compute_fingerprint(Enum.join(hashes, ":"))
  end

  @doc "Records or updates a resource fingerprint."
  def record_fingerprint(resource_id, data_or_paths, cwd_or_opts \\ [])

  def record_fingerprint(resource_id, data_or_paths, cwd) when is_binary(cwd) do
    record_fingerprint(resource_id, data_or_paths, cwd: cwd)
  end

  def record_fingerprint(resource_id, data_or_paths, opts) when is_list(opts) do
    cwd = Keyword.get(opts, :cwd, ".")
    metadata = Keyword.get(opts, :metadata, %{})
    fingerprint = compute_fingerprint(data_or_paths)
    store = load_store(cwd)

    entry = %{
      "fingerprint" => fingerprint,
      "updated_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "metadata" => metadata
    }

    updated_store = Map.put(store, resource_id, entry)
    save_store(updated_store, cwd)
    fingerprint
  end

  @doc "Checks if a stored resource fingerprint is stale compared to current data/paths."
  def stale?(resource_id, current_data_or_paths, cwd_or_opts \\ [])

  def stale?(resource_id, current_data_or_paths, cwd) when is_binary(cwd) do
    stale?(resource_id, current_data_or_paths, cwd: cwd)
  end

  def stale?(resource_id, current_data_or_paths, opts) when is_list(opts) do
    cwd = Keyword.get(opts, :cwd, ".")
    store = load_store(cwd)

    case Map.get(store, resource_id) do
      %{"fingerprint" => stored_hash} ->
        current_hash = compute_fingerprint(current_data_or_paths)
        stored_hash != current_hash

      _ ->
        true
    end
  end

  @doc "Returns details about a stored resource fingerprint, or nil if not stored."
  def get_fingerprint(resource_id, cwd_or_opts \\ [])

  def get_fingerprint(resource_id, cwd) when is_binary(cwd) do
    get_fingerprint(resource_id, cwd: cwd)
  end

  def get_fingerprint(resource_id, opts) when is_list(opts) do
    cwd = Keyword.get(opts, :cwd, ".")
    store = load_store(cwd)
    Map.get(store, resource_id)
  end

  @doc "Clears a stored resource fingerprint."
  def clear_fingerprint(resource_id, cwd_or_opts \\ [])

  def clear_fingerprint(resource_id, cwd) when is_binary(cwd) do
    clear_fingerprint(resource_id, cwd: cwd)
  end

  def clear_fingerprint(resource_id, opts) when is_list(opts) do
    cwd = Keyword.get(opts, :cwd, ".")
    store = load_store(cwd)
    updated_store = Map.delete(store, resource_id)
    save_store(updated_store, cwd)
  end

  # Store persistence helpers

  defp store_path(cwd) do
    Path.join(cwd, @store_file)
  end

  defp load_store(cwd) do
    path = store_path(cwd)

    if File.exists?(path) do
      case File.read(path) do
        {:ok, content} ->
          case Yoke.Json.decode(content) do
            {:ok, map} when is_map(map) -> map
            _ -> %{}
          end

        _ ->
          %{}
      end
    else
      %{}
    end
  end

  defp save_store(store, cwd) do
    path = store_path(cwd)

    try do
      File.mkdir_p!(Path.dirname(path))
      json = Yoke.Json.encode!(store)
      File.write!(path, json)
    rescue
      _ -> :ok
    end
  end
end
