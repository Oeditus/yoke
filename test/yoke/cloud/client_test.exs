defmodule Yoke.Cloud.ClientTest do
  @moduledoc """
  `Yoke.Cloud.Client` is the one place a review can acquire a network
  dependency it does not need (`docs/YAAS.md` §3.1 rule 1).

  These tests pin the fail-open contract: **no configuration, a dead endpoint,
  or a rejected request must never turn a successful review into a failure.**
  They use no network: the unreachable case points at a closed loopback port,
  and the rest exercise the pure resolution logic.
  """
  use ExUnit.Case, async: false
  @moduletag :tmp_dir

  alias Yoke.Cloud.Client

  # `YOKE_CLOUD_*` are read from the process environment, so every test that
  # touches them must restore the prior value.
  setup do
    prior_endpoint = System.get_env("YOKE_CLOUD_ENDPOINT")
    prior_token = System.get_env("YOKE_CLOUD_TOKEN")
    System.delete_env("YOKE_CLOUD_ENDPOINT")
    System.delete_env("YOKE_CLOUD_TOKEN")

    on_exit(fn ->
      restore("YOKE_CLOUD_ENDPOINT", prior_endpoint)
      restore("YOKE_CLOUD_TOKEN", prior_token)
    end)

    :ok
  end

  defp restore(name, nil), do: System.delete_env(name)
  defp restore(name, value), do: System.put_env(name, value)

  describe "endpoint/1" do
    test "returns nil when nothing is configured", %{tmp_dir: dir} do
      assert File.cd!(dir, fn -> Client.endpoint([]) end) == nil
    end

    test "an explicit option wins" do
      assert Client.endpoint(endpoint: "https://api.example.com") ==
               "https://api.example.com/v1/runs"
    end

    test "the environment variable is used when no option is given" do
      System.put_env("YOKE_CLOUD_ENDPOINT", "https://env.example.com")

      assert Client.endpoint([]) == "https://env.example.com/v1/runs"
    end

    test "a trailing slash does not produce a doubled path" do
      assert Client.endpoint(endpoint: "https://api.example.com/") ==
               "https://api.example.com/v1/runs"
    end

    test "an endpoint that already names the route is not suffixed again" do
      url = "https://api.example.com/v1/runs"

      assert Client.endpoint(endpoint: url) == url
    end

    test "an empty string is treated as unconfigured" do
      assert Client.endpoint(endpoint: "") == nil
    end
  end

  describe "token/1" do
    test "returns nil when unset", %{tmp_dir: dir} do
      assert File.cd!(dir, fn -> Client.token([]) end) == nil
    end

    test "an explicit option wins over the environment" do
      System.put_env("YOKE_CLOUD_TOKEN", "from-env")
      assert Client.token(token: "from-option") == "from-option"
    end
  end

  describe "redact/1" do
    test "removes the configured token from a message" do
      System.put_env("YOKE_CLOUD_TOKEN", "sk-secret-value-123")

      refute Client.redact("failed with sk-secret-value-123") =~ "sk-secret-value-123"
    end

    test "removes a bearer credential even when it is not the configured token" do
      assert Client.redact("Authorization: Bearer abc.def.ghi") =~ "[redacted]"
      refute Client.redact("Authorization: Bearer abc.def.ghi") =~ "abc.def.ghi"
    end

    test "leaves an ordinary message untouched" do
      assert Client.redact("connection refused") == "connection refused"
    end
  end

  describe "upload/2 fail-open behaviour" do
    test "skips silently when no endpoint is configured", %{tmp_dir: dir} do
      payload = %{"run_uid" => "abc"}

      assert File.cd!(dir, fn -> Client.upload(payload, []) end) == {:ok, :skipped}
    end

    test "an unreachable endpoint is skipped, never an error" do
      # Port 1 on loopback is closed, so the connection is refused immediately.
      # The point of the test is that a review must not fail because the
      # dashboard is down.
      result =
        Client.upload(%{"run_uid" => "abc"},
          endpoint: "http://127.0.0.1:1",
          timeout: 2_000
        )

      assert result == {:ok, :skipped}
    end

    test "an unencodable payload is a local error the caller can report" do
      # A pid cannot be JSON-encoded, so this exercises the encode-failure path
      # without any network access at all.
      assert {:error, message} =
               Client.upload(%{"bad" => self()}, endpoint: "https://api.example.com")

      assert message =~ "Cannot encode upload payload"
    end
  end
end
