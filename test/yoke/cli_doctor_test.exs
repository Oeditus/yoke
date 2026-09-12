defmodule Yoke.CLI.DoctorTest do
  use ExUnit.Case, async: true

  alias Yoke.CLI.Doctor

  test "run/1 generates a diagnostic report with checks" do
    report = Doctor.run(File.cwd!())

    assert report.status in [:ok, :error]
    assert is_list(report.checks)
    assert length(report.checks) >= 4
    assert is_binary(report.summary)
    assert String.contains?(report.summary, "Yoke Health & Environment Doctor")
  end
end
