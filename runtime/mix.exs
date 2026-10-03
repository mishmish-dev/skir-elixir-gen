defmodule Skir.MixProject do
  use Mix.Project
  def project do
    [app: :skir, version: "0.3.0", elixir: "~> 1.14", start_permanent: Mix.env() == :prod,
     deps: [{:jason, "~> 1.4"}, {:plug, ">= 1.16.0 and < 2.0.0", only: :test}], description: "Native Elixir runtime and SkirRPC implementation for Skir schemas",
     package: [licenses: ["MIT"], files: ["lib", "mix.exs", "README.md", "LICENSE"]]]
  end
  def application, do: [extra_applications: [:logger, :inets, :ssl]]
end
