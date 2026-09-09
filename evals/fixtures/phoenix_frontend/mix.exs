defmodule HarnessFixture.MixProject do
  use Mix.Project
  def project, do: [app: :harness_fixture, version: "0.1.0", elixir: "~> 1.19", deps: []]
  def application, do: [extra_applications: [:logger], mod: {HarnessFixture.Application, []}]
end
