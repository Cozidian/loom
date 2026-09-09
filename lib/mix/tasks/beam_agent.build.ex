defmodule Mix.Tasks.BeamAgent.Build do
  use Mix.Task

  @shortdoc "Builds the Elixir CLI and a terminal frontend (--frontend go|rust|all)"

  @impl Mix.Task
  def run(args) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: [frontend: :string])
    frontend = opts[:frontend] || "go"

    if rest != [] or invalid != [] or frontend not in ["go", "rust", "all"] do
      Mix.raise("Usage: mix beam_agent.build [--frontend go|rust|all]")
    end

    root = File.cwd!()

    if frontend in ["go", "all"], do: build_go(root)
    if frontend in ["rust", "all"], do: build_rust(root)

    Mix.shell().info("Building Elixir escript")
    Mix.Task.run("escript.build")
  end

  defp build_go(root) do
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
  end

  defp build_rust(root) do
    cargo = System.find_executable("cargo") || Mix.raise("Rust/Cargo is required to build ION")
    Mix.shell().info("Building ION / Ratatui")
    target = Path.join(root, "cmd/beam_agent_ion/target")

    case System.cmd(
           cargo,
           [
             "build",
             "--release",
             "--locked",
             "--manifest-path",
             "cmd/beam_agent_ion/Cargo.toml",
             "--target-dir",
             target
           ],
           cd: root,
           into: IO.stream(:stdio, :line)
         ) do
      {_output, 0} ->
        File.cp!(Path.join(target, "release/beam_agent_ion"), Path.join(root, "beam_agent_ion"))
        File.chmod!(Path.join(root, "beam_agent_ion"), 0o755)

      {_output, status} ->
        Mix.raise("Rust TUI build failed with status #{status}")
    end
  end
end
