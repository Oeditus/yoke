defmodule Yoke.UUID do
  @moduledoc """
  UUID generation for session identifiers and CI run identifiers.

  Three byte-identical v4 generators used to live in `Yoke.CLI.Main`,
  `Yoke.Brain.SessionStore` and `Yoke.Client.DeepSeekAPI`, plus a fourth,
  correctly-implemented v7 in `Yoke.CI.Review`. They produced the same shape
  from the same code, so a caller had no way to know which one to use.

  ## v4 vs v7

    * `v4/0` -- fully random. Use for opaque identifiers where ordering does
      not matter (a session's own id).
    * `v7/0` -- time-ordered (48-bit Unix milliseconds, then random bits). Use
      where runs must sort chronologically without a database, such as the CI
      run uid.
  """

  @doc "Returns a random (version 4) UUID string."
  @spec v4() :: String.t()
  def v4 do
    <<a::32, b::16, c::16, d::16, e::48>> = :crypto.strong_rand_bytes(16)

    :io_lib.format("~8.16.0b-~4.16.0b-~4.16.0b-~4.16.0b-~12.16.0b", [a, b, c, d, e])
    |> IO.iodata_to_binary()
  end

  @doc """
  Returns a time-ordered (version 7) UUID string.

  The first 48 bits are big-endian Unix milliseconds, so lexicographic order
  matches chronological order.
  """
  @spec v7() :: String.t()
  def v7 do
    ms = System.system_time(:millisecond)
    <<ms_hi::16, ms_lo::32>> = <<ms::48>>
    <<r1, r2, r3, r4, r5, r6, r7, r8, r9, r10>> = :crypto.strong_rand_bytes(10)

    # Byte layout of a UUIDv7 (16 bytes):
    #   0..5  ms_hi, ms_lo          (48-bit timestamp)
    #   6     version_byte          (0x70 | random nibble)
    #   7     r3
    #   8     variant_byte          (0x80 | random 6 bits)
    #   9..15 r4..r10
    version_byte = Bitwise.bor(0x70, Bitwise.band(r1, 0x0F))
    variant_byte = Bitwise.bor(0x80, Bitwise.band(r2, 0x3F))

    <<g1::binary-size(4), g2::binary-size(2), g3::binary-size(2), g4::binary-size(2),
      g5::binary-size(6)>> =
      <<ms_hi::16, ms_lo::32, version_byte, r3, variant_byte, r4, r5, r6, r7, r8, r9, r10>>

    hex = fn bytes -> Base.encode16(bytes, case: :lower) end
    "#{hex.(g1)}-#{hex.(g2)}-#{hex.(g3)}-#{hex.(g4)}-#{hex.(g5)}"
  end
end
