defmodule SkirExample.MixProject do
  use Mix.Project

  def project do
    [
      app: :skir_example,
      version: "0.2.0",
      elixir: "~> 1.14",
      test_coverage: [
        output: "../.artifacts/coverage",
        ignore_modules: [~r/^Example\.Protocol\./],
        summary: [threshold: 90]
      ],
      deps: [
        {:skir_elixir_client, path: "../../skir-elixir-client"},
        {:plug_cowboy, "~> 2.9", only: :test}
      ]
    ]
  end

  def application, do: [extra_applications: [:logger]]
end
