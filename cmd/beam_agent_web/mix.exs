defmodule BeamAgentWeb.MixProject do
  use Mix.Project

  def project do
    [app: :beam_agent_web, version: "0.1.0", elixir: "~> 1.19", deps: deps()]
  end

  def application do
    [extra_applications: [:logger, :crypto, :inets, :ssl], mod: {BeamAgentWeb.Application, []}]
  end

  defp deps do
    [
      {:phoenix, "~> 1.8.0"},
      {:phoenix_html, "~> 4.0"},
      {:plug_cowboy, "~> 2.7"},
      {:jason, "~> 1.4"},
      {:beam_agent, path: "../..", only: :test}
    ]
  end
end
