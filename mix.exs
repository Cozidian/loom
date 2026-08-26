defmodule BeamAgent.MixProject do
  use Mix.Project

  def project do
    [
      app: :beam_agent,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      escript: [main_module: BeamAgent.CLI, name: "beam_agent"],
      deps: []
    ]
  end

  def application do
    [
      extra_applications: [:crypto, :logger],
      mod: {BeamAgent.Application, []}
    ]
  end
end
