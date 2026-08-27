defmodule Mix.Tasks.BeamAgent.Build do
  use Mix.Task

  @shortdoc "Builds the Elixir CLI and its Go terminal frontend"

  @impl Mix.Task
  def run(_args) do
    root = File.cwd!()
    go = System.find_executable("go") || Mix.raise("Go is required to build the Charm TUI")

    Mix.shell().info("Building Charm TUI")

    case System.cmd(
           go,
           ["build", "-buildvcs=false", "-o", "beam_agent_tui", "./cmd/beam_agent_tui"],
           cd: root,
           into: IO.stream(:stdio, :line)
         ) do
      {_output, 0} -> :ok
      {_output, status} -> Mix.raise("Go TUI build failed with status #{status}")
    end

    Mix.shell().info("Building Elixir escript")
    Mix.Task.run("escript.build")
  end
end
