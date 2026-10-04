defmodule SkirExample.MixProject do
  use Mix.Project
  def project do
    [app: :skir_example, version: "0.2.0", elixir: "~> 1.14",
     deps: [{:skir, path: "../runtime"}, {:plug_cowboy, "~> 2.9", only: :test}]]
  end
  def application, do: [extra_applications: [:logger]]
end
