defmodule Yoke.CudaDetectorTest do
  use ExUnit.Case, async: false

  alias Yoke.CudaDetector

  describe "cpu_only?/0" do
    test "returns true when EXLA_CPU_ONLY is 1 or true" do
      for val <- ["1", "true"] do
        System.put_env("EXLA_CPU_ONLY", val)
        assert CudaDetector.cpu_only?()
      end
    after
      System.delete_env("EXLA_CPU_ONLY")
    end

    test "returns true when XLA_TARGET is cpu" do
      System.put_env("XLA_TARGET", "cpu")
      assert CudaDetector.cpu_only?()
    after
      System.delete_env("XLA_TARGET")
    end

    test "returns false when CPU mode is not set" do
      System.delete_env("EXLA_CPU_ONLY")
      System.delete_env("XLA_TARGET")
      refute CudaDetector.cpu_only?()
    end
  end

  describe "configured_cuda?/0" do
    test "detects XLA_TARGET cuda values" do
      for target <- ["cuda", "cuda12", "cuda13"] do
        System.put_env("XLA_TARGET", target)
        assert CudaDetector.configured_cuda?()
      end
    after
      System.delete_env("XLA_TARGET")
    end

    test "detects RAGEX_EXLA_CLIENT" do
      System.put_env("RAGEX_EXLA_CLIENT", "cuda")
      assert CudaDetector.configured_cuda?()
    after
      System.delete_env("RAGEX_EXLA_CLIENT")
    end

    test "detects Application env for :ragex, :exla_client" do
      Application.put_env(:ragex, :exla_client, :cuda)
      assert CudaDetector.configured_cuda?()
    after
      Application.delete_env(:ragex, :exla_client)
    end
  end

  describe "detect/0 and auto_configure/0" do
    test "detects GPU or returns no_gpu without crashing" do
      result = CudaDetector.detect()

      case result do
        {:ok, info} ->
          assert is_binary(info.target)
          assert info.target in ["cuda", "cuda12", "cuda13"]
          assert is_list(info.lib_dirs)

        :no_gpu ->
          assert true
      end
    end

    test "auto_configure respects explicit CPU mode" do
      System.put_env("EXLA_CPU_ONLY", "true")
      assert CudaDetector.auto_configure() == :cpu_only
    after
      System.delete_env("EXLA_CPU_ONLY")
    end
  end
end
