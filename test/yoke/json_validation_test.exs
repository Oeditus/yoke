defmodule Yoke.Validation.JSONTest do
  use ExUnit.Case, async: true

  alias Yoke.Validation.JSON

  test "validate_arguments/2 verifies required fields and property types" do
    schema = %{
      "type" => "object",
      "properties" => %{
        "path" => %{"type" => "string"},
        "count" => %{"type" => "integer"}
      },
      "required" => ["path"]
    }

    assert :ok = JSON.validate_arguments(schema, %{"path" => "lib/app.ex", "count" => 5})

    assert {:error, "Missing required argument(s): path"} =
             JSON.validate_arguments(schema, %{"count" => 5})

    assert {:error, _} = JSON.validate_arguments(schema, %{"path" => 123})
  end
end
