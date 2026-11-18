defmodule Yoke.CLI.FileSystemMac do
  @moduledoc """
  Manages escript extraction of `file_system`'s `mac_listener` helper on macOS.

  `mix escript.build` bundles `.beam` and `.app` files into a zip archive and
  omits `priv/` directories. On macOS, `FileSystem.Backends.FsMac` requires the
  compiled `mac_listener` executable on disk and checks
  `FILESYSTEM_FSMAC_EXECUTABLE_FILE` before falling back to `:code.priv_dir/1`.

  When compiled on macOS in the `:escript` Mix environment, this module embeds
  `priv/mac_listener` (gzip-compressed) and extracts it into a user cache
  directory at escript startup, setting `FILESYSTEM_FSMAC_EXECUTABLE_FILE` if
  not already configured. On Linux and in non-escript builds, `prepare/0` is a
  compile-time no-op with zero embedded payload.
  """

  alias Yoke.CLI.EscriptAsset

  escript_build? = Code.ensure_loaded?(Mix) and Mix.env() == :escript
  mac_build? = :os.type() == {:unix, :darwin}

  listener_source_path =
    if escript_build? and mac_build? do
      [
        Application.app_dir(:file_system, "priv/mac_listener"),
        Path.join([Mix.Project.build_path(), "lib", "file_system", "priv", "mac_listener"])
      ]
      |> Enum.uniq()
      |> Enum.find(&File.regular?/1)
    end

  if listener_source_path do
    Code.ensure_compiled!(Yoke.CLI.EscriptAsset)

    @external_resource listener_source_path
    @embedded_listener_gz :zlib.gzip(File.read!(listener_source_path))
    @embedded_listener_hash Base.encode16(:crypto.hash(:sha256, @embedded_listener_gz),
                              case: :lower
                            )
                            |> binary_part(0, 16)
    @embedded_platform EscriptAsset.current_platform()

    @doc """
    Extracts the bundled `mac_listener` helper when running inside a macOS
    escript archive and sets `FILESYSTEM_FSMAC_EXECUTABLE_FILE` if unset.

    Safe and idempotent to call multiple times.
    """
    @spec prepare() :: :ok | {:error, term()}
    def prepare do
      if EscriptAsset.escript?() and EscriptAsset.current_platform() == @embedded_platform do
        target_path =
          Path.join([
            EscriptAsset.cache_root("bin", "file_system"),
            @embedded_listener_hash,
            "mac_listener"
          ])

        extract_and_configure(target_path, @embedded_listener_gz)
      else
        :ok
      end
    rescue
      reason -> {:error, reason}
    end
  else
    @doc """
    Prepares `file_system`'s `mac_listener` helper when running inside a macOS
    escript archive.

    On Linux and in non-escript builds this is a no-op.
    """
    @spec prepare() :: :ok
    def prepare, do: :ok
  end

  @doc false
  @spec extract_and_configure(Path.t(), binary()) :: :ok
  def extract_and_configure(target_path, gz_payload)
      when is_binary(target_path) and is_binary(gz_payload) do
    :ok = EscriptAsset.atomic_extract(target_path, gz_payload)

    if System.get_env("FILESYSTEM_FSMAC_EXECUTABLE_FILE") in [nil, ""] do
      System.put_env("FILESYSTEM_FSMAC_EXECUTABLE_FILE", target_path)
    end

    :ok
  end
end
