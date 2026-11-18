defmodule Yoke.CLI.EscriptAsset do
  @moduledoc false

  @doc "Returns true when running inside an escript archive."
  @spec escript?() :: boolean()
  def escript? do
    case :escript.script_name() do
      [_ | _] -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  @doc "Returns `{os_type, normalized_arch}` for the current host."
  @spec current_platform() :: {{atom(), atom()}, String.t()}
  def current_platform do
    arch =
      case :erlang.system_info(:system_architecture)
           |> to_string()
           |> String.split("-")
           |> hd() do
        "arm64" -> "aarch64"
        other -> other
      end

    {:os.type(), arch}
  end

  @doc "Returns a writable cache directory under `~/.cache/yoke` or the system temp dir."
  @spec cache_root(String.t(), String.t()) :: Path.t()
  def cache_root(category, app_name) when is_binary(category) and is_binary(app_name) do
    home_cache =
      case System.user_home() do
        home when is_binary(home) and home != "" ->
          Path.join([home, ".cache", "yoke", category, app_name])

        _ ->
          nil
      end

    if home_cache && writable_dir?(home_cache) do
      home_cache
    else
      Path.join([System.tmp_dir!(), "yoke_#{category}", app_name])
    end
  end

  @doc "Atomically extracts a gzip-compressed binary to `target_path` with mode `0o755`."
  @spec atomic_extract(Path.t(), binary()) :: :ok
  def atomic_extract(target_path, gz_payload)
      when is_binary(target_path) and is_binary(gz_payload) do
    unless File.regular?(target_path) do
      File.mkdir_p!(Path.dirname(target_path))

      tmp_path = "#{target_path}.tmp.#{:erlang.unique_integer([:positive])}"
      File.write!(tmp_path, :zlib.gunzip(gz_payload))
      File.chmod!(tmp_path, 0o755)

      case File.rename(tmp_path, target_path) do
        :ok ->
          :ok

        {:error, _} ->
          File.rm(tmp_path)

          unless File.regular?(target_path) do
            raise("Failed to extract #{Path.basename(target_path)}")
          end
      end
    end

    :ok
  end

  defp writable_dir?(dir) do
    File.mkdir_p(dir) == :ok
  rescue
    _ -> false
  end
end
