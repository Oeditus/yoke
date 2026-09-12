defmodule Yoke.Tool.Approval.PreviewTest do
  use ExUnit.Case, async: true
  alias Yoke.Tool.Approval.Preview

  test "builds escaped ASCII JSON preview for tool operation" do
    op = %{"command" => "rm -rf /tmp/foo\u001b[31m", "workspace" => "/app"}
    preview = Preview.build(op)

    assert is_binary(preview)
    refute String.contains?(preview, "\u001b")
    assert {:ok, _} = Preview.validate(preview)
  end

  test "returns :unavailable for non-map or oversized inputs" do
    assert :unavailable == Preview.build("not a map")
  end
end
