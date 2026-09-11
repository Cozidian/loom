defmodule Mix.Tasks.BeamAgent.Build do
  use Mix.Task

  @shortdoc "One-time build for CLI and clients (--frontend rust|go|web|all)"

  @impl Mix.Task
  def run(args) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: [frontend: :string])
    frontend = opts[:frontend] || "standard"

    if rest != [] or invalid != [] or frontend not in ["standard", "go", "rust", "web", "all"] do
      Mix.raise("Usage: mix beam_agent.build [--frontend rust|go|web|all]")
    end

    root = File.cwd!()

    if frontend in ["go", "all"], do: build_go(root)
    if frontend in ["standard", "rust", "all"], do: build_rust(root)
    if frontend in ["standard", "web", "all"], do: build_web(root)

    Mix.shell().info("Building Elixir escript")
    Mix.Task.run("escript.build")
    # Compatibility entry point for existing scripts; both run the same CLI.
    File.cp!("loom", "beam_agent")
    File.chmod!("beam_agent", 0o755)
  end

  defp build_web(root) do
    mix = System.find_executable("mix") || Mix.raise("Elixir/Mix is required for Desk")
    directory = Path.join(root, "cmd/beam_agent_web")

    for args <- [["deps.get"], ["compile", "--warnings-as-errors"]] do
      Mix.shell().info("Preparing Phoenix Desk: mix #{Enum.join(args, " ")}")

      case System.cmd(mix, args,
             cd: directory,
             env: [{"MIX_ENV", "dev"}],
             into: IO.stream(:stdio, :line)
           ) do
        {_, 0} -> :ok
        {_, status} -> Mix.raise("Desk build failed with status #{status}")
      end
    end
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
        destination = Path.join(root, "beam_agent_ion")
        temporary = destination <> ".#{System.unique_integer([:positive])}.tmp"

        # Replace the inode atomically: overwriting a running Mach-O executable
        # can leave macOS using its old cached code signature on the next launch.
        try do
          File.cp!(Path.join(target, "release/beam_agent_ion"), temporary)
          File.chmod!(temporary, 0o755)
          File.rename!(temporary, destination)
        after
          File.rm(temporary)
        end

      {_output, status} ->
        Mix.raise("Rust TUI build failed with status #{status}")
    end
  end
end
