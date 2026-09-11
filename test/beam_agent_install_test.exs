defmodule Mix.Tasks.BeamAgent.InstallTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.BeamAgent.Install

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "beam_agent_install_root_#{System.unique_integer([:positive])}"
      )

    bin_dir =
      Path.join(System.tmp_dir!(), "beam_agent_install_bin_#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)

    on_exit(fn ->
      File.rm_rf!(root)
      File.rm_rf!(bin_dir)
    end)

    %{root: root, bin_dir: bin_dir}
  end

  test "links the executable into a fresh bin directory", %{root: root, bin_dir: bin_dir} do
    executable = write_executable(root)

    assert {:ok, target, ^executable} = Install.link(root, bin_dir)
    assert File.read_link!(target) == executable
  end

  test "replaces a previously managed link", %{root: root, bin_dir: bin_dir} do
    executable = write_executable(root)
    assert {:ok, target, _} = Install.link(root, bin_dir)
    assert {:ok, ^target, ^executable} = Install.link(root, bin_dir)
    assert File.read_link!(target) == executable
  end

  test "refuses to overwrite an unmanaged file", %{root: root, bin_dir: bin_dir} do
    write_executable(root)
    File.mkdir_p!(bin_dir)
    File.write!(Path.join(bin_dir, "loom"), "not ours")

    assert {:error, :occupied, target} = Install.link(root, bin_dir)
    assert File.read!(target) == "not ours"
  end

  test "reports a missing executable", %{root: root, bin_dir: bin_dir} do
    assert {:error, :missing_executable, path} = Install.link(root, bin_dir)
    assert path == Path.join(root, "loom")
  end

  test "default_bin_dir sits under the user's home" do
    assert Install.default_bin_dir() == Path.join(System.user_home!(), ".local/bin")
  end

  test "on_path?/2 checks PATH membership regardless of trailing slashes" do
    assert Install.on_path?("/tmp/example", "/usr/bin:/tmp/example/:/bin")
    refute Install.on_path?("/tmp/example", "/usr/bin:/bin")
  end

  defp write_executable(root) do
    path = Path.join(root, "loom")
    File.write!(path, "#!/bin/sh\necho loom\n")
    File.chmod!(path, 0o755)
    path
  end
end
