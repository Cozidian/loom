defmodule Mix.Tasks.Loom.Build do
  use Mix.Task
  @shortdoc "Build Loom and its clients (--frontend rust|go|web|all)"
  def run(args), do: Mix.Task.run("beam_agent.build", args)
end
