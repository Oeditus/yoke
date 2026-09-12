defmodule Yoke.Web.Network.AddressPolicy do
  @moduledoc """
  Default-deny classification for resolved web destinations.
  Validates IPv4 and IPv6 addresses against private, loopback, link-local, and restricted ranges.
  """

  @type address :: :inet.ip_address()

  @doc "Allows a globally routable public address and blocks local or special-use ranges."
  @spec validate(term()) :: :ok | {:error, String.t()}
  def validate(address) do
    if public?(address) do
      :ok
    else
      {:error, "Destination IP address is blocked (private/loopback/restricted range)"}
    end
  end

  @doc "Requires every resolved address to be public."
  @spec validate_all([address()]) :: {:ok, [address()]} | {:error, String.t()}
  def validate_all([_ | _] = addresses) do
    if Enum.all?(addresses, &public?/1) do
      {:ok, Enum.uniq(addresses)}
    else
      {:error,
       "One or more resolved IP addresses are blocked (private/loopback/restricted range)"}
    end
  end

  def validate_all(_addresses) do
    {:error, "No valid IP addresses provided"}
  end

  # IPv4 Restrictions
  defp public?({0, _b, _c, _d}), do: false
  defp public?({10, _b, _c, _d}), do: false
  defp public?({100, b, _c, _d}) when b in 64..127, do: false
  defp public?({127, _b, _c, _d}), do: false
  defp public?({169, 254, _c, _d}), do: false
  defp public?({172, b, _c, _d}) when b in 16..31, do: false
  defp public?({192, 0, 0, _d}), do: false
  defp public?({192, 0, 2, _d}), do: false
  defp public?({192, 88, 99, _d}), do: false
  defp public?({192, 168, _c, _d}), do: false
  defp public?({198, b, _c, _d}) when b in 18..19, do: false
  defp public?({198, 51, 100, _d}), do: false
  defp public?({203, 0, 113, _d}), do: false

  defp public?({a, b, c, d}) do
    Enum.all?([a, b, c, d], &byte?/1) and a in 1..223
  end

  # IPv6 Restrictions
  defp public?({0x2001, 0, _c, _d, _e, _f, _g, _h}), do: false
  defp public?({0x2001, 2, 0, _d, _e, _f, _g, _h}), do: false
  defp public?({0x2001, b, _c, _d, _e, _f, _g, _h}) when b in 0x10..0x2F, do: false
  defp public?({0x2001, 0xDB8, _c, _d, _e, _f, _g, _h}), do: false
  defp public?({0x2002, _b, _c, _d, _e, _f, _g, _h}), do: false

  defp public?({a, b, c, d, e, f, g, h}) do
    values = [a, b, c, d, e, f, g, h]
    Enum.all?(values, &word?/1) and a in 0x2000..0x3FFF
  end

  defp public?(_address), do: false

  defp byte?(value), do: is_integer(value) and value in 0..255
  defp word?(value), do: is_integer(value) and value in 0..65_535
end
