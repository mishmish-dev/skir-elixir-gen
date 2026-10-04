defmodule Skir.ColdStartTest do
  use ExUnit.Case, async: false
  @moduletag timeout: 30_000
  for scenario <- ["defaults", "codecs", "descriptors", "concurrent"] do
    @scenario scenario
    test "mutually recursive generated modules from a cold #{@scenario} start" do
      script = Path.expand("../../scripts/cold-start.exs", __DIR__)

      {output, status} =
        System.cmd("mix", ["run", "--no-compile", script, @scenario],
          env: [{"MIX_ENV", "test"}],
          stderr_to_stdout: true
        )

      assert status == 0, output
      assert output =~ "PASS: cold start #{@scenario}"
    end
  end
end
