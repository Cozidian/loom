defmodule Mix.Tasks.Loom.Install do
  use Mix.Task
  @shortdoc "Build Loom and link `loom` onto your PATH (--bin-dir DIR, --no-build)"
  def run(args), do: Mix.Task.run("beam_agent.install", args)
end
