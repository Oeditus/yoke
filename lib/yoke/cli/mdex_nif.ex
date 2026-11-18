defmodule Yoke.CLI.MdexNif do
  @moduledoc """
  Manages availability and escript extraction of the `mdex_native` NIF.

  `mix escript.build` bundles `.beam` and `.app` files into a zip archive and
  omits `priv/` directories. Furthermore, `:erlang.load_nif/2` requires a real
  filesystem path for `dlopen()`.

  When compiled in the `:escript` Mix environment, this module embeds the
  compiled `mdex_native` NIF shared library (gzip-compressed) and extracts it
  into a user cache directory at escript startup, prepending a matching
  `ebin/` directory to the Erlang code path so `Application.app_dir/2`
  resolves `priv/native/` on disk.

  When running on an incompatible OS/architecture (e.g. a Linux-built escript
  executed on macOS) or when no NIF library is present on disk, `available?/0`
  returns `false` *without* loading `MDExNative.Native`, preventing noisy
  `@on_load` / `dlopen` errors and allowing callers to use a pure-Elixir
  Markdown fallback.
  """

  @persistent_key {__MODULE__, :available}

  # Embed the NIF binary only for `:escript` builds so dev/test/release builds
  # stay lean and continue using their own `priv/native/` directory directly.
  @escript_build? Code.ensure_loaded?(Mix) and Mix.env() == :escript

  nif_source_path =
    if @escript_build? do
      candidates =
        [
          Application.app_dir(:mdex_native, "priv/native"),
          Path.join([Mix.Project.build_path(), "lib", "mdex_native", "priv", "native"])
        ]
        |> Enum.uniq()
        |> Enum.filter(&File.dir?/1)

      Enum.find_value(candidates, fn dir ->
        case File.ls(dir) do
          {:ok, files} ->
            files
            |> Enum.sort()
            |> Enum.find(&String.ends_with?(&1, [".so", ".dll", ".dylib"]))
            |> case do
              nil -> nil
              file -> Path.join(dir, file)
            end

          _ ->
            nil
        end
      end)
    end

  if nif_source_path do
    @external_resource nif_source_path
    @embedded_nif_name Path.basename(nif_source_path)
    @embedded_nif_gz :zlib.gzip(File.read!(nif_source_path))
    @embedded_nif_hash Base.encode16(:crypto.hash(:sha256, @embedded_nif_gz), case: :lower)
                       |> binary_part(0, 16)
    @embedded_os_type :os.type()
    @embedded_arch (case :erlang.system_info(:system_architecture)
                         |> to_string()
                         |> String.split("-")
                         |> hd() do
                      "arm64" -> "aarch64"
                      other -> other
                    end)

    @doc """
    Prepares the `mdex_native` NIF when running inside an escript archive.

    Safe and idempotent to call multiple times.
    """
    @spec prepare() :: :ok | {:error, term()}
    def prepare do
      if escript?() do
        if current_platform() == {@embedded_os_type, @embedded_arch} do
          app_dir = Path.join(cache_root(), @embedded_nif_hash)
          extract_and_register(app_dir, @embedded_nif_name, @embedded_nif_gz)
        else
          :persistent_term.put(@persistent_key, false)
          {:error, :incompatible_platform}
        end
      else
        :ok
      end
    rescue
      reason ->
        :persistent_term.put(@persistent_key, false)
        {:error, reason}
    end

    defp escript? do
      case :escript.script_name() do
        [_ | _] -> true
        _ -> false
      end
    rescue
      _ -> false
    end

    defp current_platform do
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

    defp cache_root do
      home_cache =
        case System.user_home() do
          home when is_binary(home) and home != "" ->
            Path.join([home, ".cache", "yoke", "nif", "mdex_native"])

          _ ->
            nil
        end

      if home_cache && writable_dir?(home_cache) do
        home_cache
      else
        Path.join([System.tmp_dir!(), "yoke_nif", "mdex_native"])
      end
    end

    defp writable_dir?(dir) do
      File.mkdir_p(dir) == :ok
    rescue
      _ -> false
    end
  else
    @doc """
    Prepares the `mdex_native` NIF when running inside an escript archive.

    In builds without an embedded NIF this is a no-op.
    """
    @spec prepare() :: :ok
    def prepare, do: :ok
  end

  @doc """
  Returns `true` if `MDExNative.Native` is loaded or can be loaded cleanly
  from disk, `false` otherwise.

  Checks for the presence of the native library on disk before loading
  `MDExNative.Native` so that missing/incompatible NIFs never trigger BEAM
  `@on_load` / `dlopen` log errors.
  """
  @spec available?() :: boolean()
  def available? do
    case :persistent_term.get(@persistent_key, nil) do
      val when is_boolean(val) ->
        val

      nil ->
        result = detect_availability()
        :persistent_term.put(@persistent_key, result)
        result
    end
  end

  @doc false
  @spec reset_cache() :: :ok
  def reset_cache do
    :persistent_term.erase(@persistent_key)
    :ok
  end

  @doc false
  @spec extract_and_register(Path.t(), String.t(), binary()) :: :ok | {:error, term()}
  def extract_and_register(app_dir, nif_name, nif_gz)
      when is_binary(app_dir) and is_binary(nif_name) and is_binary(nif_gz) do
    ebin_dir = Path.join(app_dir, "ebin")
    nif_dir = Path.join([app_dir, "priv", "native"])
    nif_path = Path.join(nif_dir, nif_name)

    unless File.regular?(nif_path) do
      File.mkdir_p!(ebin_dir)
      File.mkdir_p!(nif_dir)

      tmp_path = "#{nif_path}.tmp.#{:erlang.unique_integer([:positive])}"
      File.write!(tmp_path, :zlib.gunzip(nif_gz))
      File.chmod!(tmp_path, 0o755)

      case File.rename(tmp_path, nif_path) do
        :ok ->
          :ok

        {:error, _} ->
          File.rm(tmp_path)
          unless File.regular?(nif_path), do: raise("Failed to extract #{nif_name}")
      end
    end

    unless Application.app_dir(:mdex_native) == app_dir do
      :code.add_patha(String.to_charlist(ebin_dir))
    end

    :ok
  end

  defp detect_availability do
    _ = prepare()

    cond do
      :persistent_term.get(@persistent_key, nil) == false ->
        false

      :code.is_loaded(MDExNative.Native) != false ->
        nif_callable?()

      has_nif_on_disk?() ->
        Code.ensure_loaded?(MDExNative.Native) and nif_callable?()

      true ->
        false
    end
  end

  defp has_nif_on_disk? do
    priv_dir = Application.app_dir(:mdex_native, "priv/native")

    File.dir?(priv_dir) and
      case File.ls(priv_dir) do
        {:ok, files} ->
          Enum.any?(files, &String.ends_with?(&1, [".so", ".dll", ".dylib"]))

        _ ->
          false
      end
  rescue
    _ -> false
  end

  defp nif_callable? do
    function_exported?(MDExNative.Native, :text_to_anchor, 1) and
      is_binary(MDExNative.Native.text_to_anchor("ok"))
  rescue
    _ -> false
  catch
    _, _ -> false
  end
end
