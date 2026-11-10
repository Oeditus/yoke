defmodule Yoke.CudaDetector do
  @moduledoc """
  Automatic GPU and CUDA detection for Yoke and embedded Ragex.

  Detects NVIDIA GPUs and CUDA toolkits/drivers, configuring `XLA_TARGET`,
  `RAGEX_EXLA_CLIENT`, `PATH`, and `LD_LIBRARY_PATH` so that underlying EXLA
  and Ragex compile and run with CUDA hardware acceleration automatically.
  """

  @doc """
  Runs GPU detection and configures environment and application settings for CUDA
  if a GPU is detected and CPU-only mode has not been explicitly requested.
  """
  def auto_configure do
    if cpu_only?() do
      :cpu_only
    else
      case detect() do
        {:ok, info} ->
          apply_env(info)
          {:ok, info}

        error ->
          error
      end
    end
  end

  @doc """
  Returns `true` if CPU-only mode is explicitly enforced via `EXLA_CPU_ONLY=true`
  or `XLA_TARGET=cpu`.
  """
  def cpu_only? do
    System.get_env("EXLA_CPU_ONLY") in ["1", "true"] or
      System.get_env("XLA_TARGET") == "cpu"
  end

  @doc """
  Returns `true` if CUDA has been configured in the environment or application.
  """
  def configured_cuda? do
    System.get_env("XLA_TARGET") in ["cuda", "cuda12", "cuda13"] or
      System.get_env("RAGEX_EXLA_CLIENT") == "cuda" or
      Application.get_env(:ragex, :exla_client) == :cuda
  end

  @doc """
  Returns `true` if a CUDA GPU is available or configured, and CPU-only mode is not set.
  """
  def cuda_available? do
    not cpu_only?() and (configured_cuda?() or gpu_present?())
  end

  @doc """
  Detects NVIDIA hardware, CUDA toolkits, and library directories.
  """
  def detect do
    if gpu_present?() do
      nvcc_path = find_nvcc()
      cuda_home = find_cuda_home(nvcc_path)
      target = infer_target(nvcc_path)
      lib_dirs = find_cuda_lib_dirs(cuda_home)

      bin_dir =
        cond do
          nvcc_path -> Path.dirname(nvcc_path)
          cuda_home -> Path.join(cuda_home, "bin")
          true -> nil
        end

      {:ok,
       %{
         target: target,
         nvcc: nvcc_path,
         cuda_home: cuda_home,
         bin_dir: bin_dir,
         lib_dirs: lib_dirs
       }}
    else
      :no_gpu
    end
  end

  @doc """
  Checks for the presence of NVIDIA GPU devices or drivers.
  """
  def gpu_present? do
    File.exists?("/dev/nvidia0") or
      File.exists?("/dev/nvidiactl") or
      File.exists?("/dev/nvhost-ctrl") or
      smi_present?()
  end

  defp smi_present? do
    case System.find_executable("nvidia-smi") do
      nil -> false
      smi -> match?({_, 0}, System.cmd(smi, ["-L"], stderr_to_stdout: true))
    end
  rescue
    _ -> false
  end

  @doc """
  Finds the `nvcc` compiler executable in PATH or standard installation locations.
  """
  def find_nvcc do
    case System.find_executable("nvcc") do
      nil ->
        candidates =
          Path.wildcard(
            Path.expand("~/.local/share/yoke/cuda*/lib/python*/site-packages/nvidia/cu*/bin/nvcc")
          ) ++
            [
              "/usr/local/cuda/bin/nvcc",
              "/opt/cuda/bin/nvcc",
              "/usr/bin/nvcc"
            ] ++
            Path.wildcard("/usr/local/cuda-*/bin/nvcc")

        Enum.find(candidates, &File.exists?/1)

      path ->
        path
    end
  rescue
    _ -> nil
  end

  @doc """
  Locates the CUDA root directory from environment variables, nvcc path, or standard paths.
  """
  def find_cuda_home(nvcc_path) do
    cond do
      env_home = System.get_env("CUDA_HOME") || System.get_env("CUDA_PATH") ->
        if File.dir?(env_home), do: env_home, else: nil

      nvcc_path ->
        # nvcc is in <cuda_home>/bin/nvcc
        Path.dirname(Path.dirname(nvcc_path))

      true ->
        candidates =
          Path.wildcard(
            Path.expand("~/.local/share/yoke/cuda*/lib/python*/site-packages/nvidia/cu*")
          ) ++
            ["/usr/local/cuda", "/opt/cuda"] ++
            Path.wildcard("/usr/local/cuda-*")

        Enum.find(candidates, &File.dir?/1)
    end
  rescue
    _ -> nil
  end

  @doc """
  Finds CUDA and companion library directories (libcudart, libcublas, libcudnn, libnccl, etc.).
  """
  def find_cuda_lib_dirs(cuda_home) do
    if cuda_home && File.dir?(cuda_home) do
      candidates = [
        Path.join(cuda_home, "lib"),
        Path.join(cuda_home, "lib64"),
        Path.join([cuda_home, "..", "cudnn", "lib"]),
        Path.join([cuda_home, "..", "nccl", "lib"]),
        Path.join([cuda_home, "..", "nvshmem", "lib"])
      ]

      candidates
      |> Enum.map(&Path.expand/1)
      |> Enum.filter(&File.dir?/1)
    else
      []
    end
  rescue
    _ -> []
  end

  @doc """
  Infers the appropriate XLA target ("cuda13", "cuda12", or "cuda").
  """
  def infer_target(nvcc_path) do
    case System.get_env("XLA_TARGET") do
      target when is_binary(target) and target not in ["", "cpu"] ->
        target

      _ ->
        infer_from_nvcc(nvcc_path) || infer_from_smi() || "cuda13"
    end
  end

  defp infer_from_nvcc(nil), do: nil

  defp infer_from_nvcc(path) do
    case System.cmd(path, ["--version"]) do
      {output, 0} ->
        cond do
          output =~ "release 13." -> "cuda13"
          output =~ "release 12." -> "cuda12"
          true -> "cuda"
        end

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  defp infer_from_smi do
    with smi when is_binary(smi) <- System.find_executable("nvidia-smi"),
         {output, 0} <- System.cmd(smi, []) do
      case Regex.run(~r/CUDA Version:\s*(\d+)\.(\d+)/, output) do
        [_, major, _minor] ->
          case String.to_integer(major) do
            v when v >= 13 -> "cuda13"
            12 -> "cuda12"
            _ -> "cuda"
          end

        _ ->
          nil
      end
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end

  @doc """
  Applies detected CUDA configuration to environment variables and application config.
  """
  def apply_env(info) do
    if is_nil(System.get_env("XLA_TARGET")) or System.get_env("XLA_TARGET") == "" do
      System.put_env("XLA_TARGET", info.target)
    end

    if is_nil(System.get_env("RAGEX_EXLA_CLIENT")) or System.get_env("RAGEX_EXLA_CLIENT") == "" do
      System.put_env("RAGEX_EXLA_CLIENT", "cuda")
    end

    Application.put_env(:ragex, :exla_client, :cuda)

    if info.bin_dir && File.dir?(info.bin_dir) do
      prepend_path("PATH", info.bin_dir)
    end

    Enum.each(info.lib_dirs, fn dir ->
      prepend_path("LD_LIBRARY_PATH", dir)
    end)

    if info.cuda_home do
      if is_nil(System.get_env("CUDA_HOME")), do: System.put_env("CUDA_HOME", info.cuda_home)
      if is_nil(System.get_env("CUDA_PATH")), do: System.put_env("CUDA_PATH", info.cuda_home)

      case System.get_env("XLA_FLAGS") do
        nil ->
          System.put_env("XLA_FLAGS", "--xla_gpu_cuda_data_dir=#{info.cuda_home}")

        flags ->
          unless flags =~ "--xla_gpu_cuda_data_dir=" do
            System.put_env("XLA_FLAGS", "#{flags} --xla_gpu_cuda_data_dir=#{info.cuda_home}")
          end
      end
    end
  end

  defp prepend_path(var, dir) do
    current = System.get_env(var, "")
    entries = String.split(current, ":", trim: true)

    unless dir in entries do
      new_val = if current == "", do: dir, else: "#{dir}:#{current}"
      System.put_env(var, new_val)
    end
  end
end
