defmodule Mix.Tasks.BeamAgent.Install do
  use Mix.Task

  @shortdoc "Build Loom and link `loom` onto your PATH (--bin-dir DIR, --no-build)"

  @moduledoc """
  Builds Loom (unless `--no-build` is given) and symlinks the resulting
  `loom` executable into a directory on your PATH, defaulting to
  `~/.local/bin`. The checkout still has to stay put: the executable finds
  its sibling files (Desk, ION) relative to itself, not the symlink.
  """

  @impl Mix.Task
  def run(args) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [frontend: :string, bin_dir: :string, build: :boolean]
      )

    if rest != [] or invalid != [] do
      Mix.raise(
        "Usage: mix beam_agent.install [--frontend rust|go|web|all] [--bin-dir DIR] [--no-build]"
      )
    end

    if Keyword.get(opts, :build, true) do
      build_args = if opts[:frontend], do: ["--frontend", opts[:frontend]], else: []
      Mix.Task.run("beam_agent.build", build_args)
    end

    bin_dir = opts[:bin_dir] || default_bin_dir()

    case link(File.cwd!(), bin_dir) do
      {:ok, link_path, executable} ->
        Mix.shell().info("Linked #{link_path} -> #{executable}")

        if on_path?(bin_dir) do
          Mix.shell().info("Run `loom` from any directory to start.")
        else
          Mix.shell().info(path_hint(bin_dir))
        end

      {:error, :missing_executable, path} ->
        Mix.raise("#{path} not found. Run mix loom.build first, or drop --no-build.")

      {:error, :occupied, path} ->
        Mix.raise(
          "#{path} already exists and isn't a symlink Loom manages. " <>
            "Remove it or install elsewhere with --bin-dir."
        )
    end
  end

  @doc false
  def link(root, bin_dir) do
    executable = Path.join(root, "loom")

    if File.regular?(executable) do
      File.mkdir_p!(bin_dir)
      target = Path.join(bin_dir, "loom")

      case File.read_link(target) do
        {:ok, _existing_target} ->
          File.rm!(target)
          File.ln_s!(executable, target)
          {:ok, target, executable}

        {:error, :enoent} ->
          File.ln_s!(executable, target)
          {:ok, target, executable}

        {:error, _not_a_symlink} ->
          {:error, :occupied, target}
      end
    else
      {:error, :missing_executable, executable}
    end
  end

  @doc false
  def default_bin_dir do
    Path.join(System.user_home!(), ".local/bin")
  end

  @doc false
  def on_path?(dir, path_env \\ System.get_env("PATH") || "") do
    expanded = Path.expand(dir)

    path_env
    |> String.split(":")
    |> Enum.any?(&(&1 != "" and Path.expand(&1) == expanded))
  end

  @doc false
  def path_hint(bin_dir) do
    """
    #{bin_dir} is not on your PATH yet. Add it in your shell profile, then open a new terminal:

        export PATH="#{bin_dir}:$PATH"
    """
  end
end
