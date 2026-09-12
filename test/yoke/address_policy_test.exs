defmodule Yoke.Web.Network.AddressPolicyTest do
  use ExUnit.Case, async: true
  alias Yoke.Web.Network.AddressPolicy

  test "blocks private and loopback IPv4 addresses" do
    assert {:error, _} = AddressPolicy.validate({127, 0, 0, 1})
    assert {:error, _} = AddressPolicy.validate({10, 0, 1, 5})
    assert {:error, _} = AddressPolicy.validate({192, 168, 1, 1})
    assert {:error, _} = AddressPolicy.validate({172, 16, 0, 1})
    assert {:error, _} = AddressPolicy.validate({169, 254, 169, 254})
  end

  test "allows public IPv4 addresses" do
    assert :ok = AddressPolicy.validate({1, 1, 1, 1})
    assert :ok = AddressPolicy.validate({8, 8, 8, 8})
    assert :ok = AddressPolicy.validate({93, 184, 216, 34})
  end
end
