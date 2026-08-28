defmodule BeamAgent.Auth.Keyring.Native do
  @moduledoc "OS keyring backend using macOS Keychain or Secret Service."
  @behaviour BeamAgent.Auth.Keyring

  @service "beam-agent"
  @command_timeout 60_000
  @expect_script """
  log_user 0
  set timeout 60
  spawn -noecho $env(BEAM_AGENT_CREDENTIAL_EXECUTABLE) add-generic-password \
    -a $env(BEAM_AGENT_CREDENTIAL_REFERENCE) -s beam-agent -U -w
  expect "password data for new item: "
  send_user "BEAM_AGENT_KEYRING_READY\\n"
  expect_user -re {([^\\r\\n]*)\\r?\\n}
  set secret $expect_out(1,string)
  send -- "$secret\\r"
  expect "retype password for new item: "
  send -- "$secret\\r"
  expect eof
  set result [wait]
  exit [lindex $result 3]
  """

  @impl true
  def init(_opts) do
    case backend() do
      nil -> {:ok, :unavailable}
      backend -> {:ok, backend}
    end
  end

  def put(_reference, _secret, :unavailable),
    do: {:error, :secure_credential_store_unavailable}

  @impl true
  def put(reference, secret, {:macos, executable, expect} = state) do
    case run_macos_with_input(expect, executable, reference, secret) do
      {:ok, _output} -> {:ok, state}
      {:error, reason} -> {:error, {:credential_store_failed, reason}}
    end
  end

  def put(reference, secret, {:secret_service, executable} = state) do
    args = ["store", "--label=BeamAgent #{reference}", "service", @service, "account", reference]

    case run_with_input(executable, args, secret) do
      {:ok, _output} -> {:ok, state}
      {:error, reason} -> {:error, {:credential_store_failed, reason}}
    end
  end

  @impl true
  def fetch(_reference, :unavailable),
    do: {{:error, :secure_credential_store_unavailable}, :unavailable}

  def fetch(reference, {:macos, executable, _expect} = state) do
    result =
      run(executable, ["find-generic-password", "-a", reference, "-s", @service, "-w"])

    {normalize_fetch(result), state}
  end

  def fetch(reference, {:secret_service, executable} = state) do
    result = run(executable, ["lookup", "service", @service, "account", reference])
    {normalize_fetch(result), state}
  end

  @impl true
  def delete(_reference, :unavailable), do: {:ok, :unavailable}

  def delete(reference, {:macos, executable, _expect} = state) do
    case run(executable, ["delete-generic-password", "-a", reference, "-s", @service]) do
      {:ok, _output} ->
        {:ok, state}

      {:error, {_status, output}} ->
        if String.contains?(output, "could not be found"),
          do: {:ok, state},
          else: {:error, {:credential_delete_failed, output}}

      {:error, reason} ->
        {:error, {:credential_delete_failed, reason}}
    end
  end

  def delete(reference, {:secret_service, executable} = state) do
    case run(executable, ["clear", "service", @service, "account", reference]) do
      {:ok, _output} -> {:ok, state}
      {:error, reason} -> {:error, {:credential_delete_failed, reason}}
    end
  end

  defp backend do
    security = System.find_executable("security")
    expect = System.find_executable("expect")
    secret_tool = System.find_executable("secret-tool")

    cond do
      match?({:unix, :darwin}, :os.type()) and is_binary(security) and is_binary(expect) ->
        {:macos, security, expect}

      is_binary(secret_tool) ->
        {:secret_service, secret_tool}

      true ->
        nil
    end
  end

  defp normalize_fetch({:ok, output}) do
    case String.trim_trailing(output) do
      "" -> {:error, :credential_not_found}
      secret -> {:ok, secret}
    end
  end

  defp normalize_fetch({:error, _reason}), do: {:error, :credential_not_found}

  defp run(executable, args) do
    case System.cmd(executable, args, stderr_to_stdout: true, env: sanitized_env()) do
      {output, 0} -> {:ok, output}
      {output, status} -> {:error, {status, String.trim(output)}}
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  # Both helpers receive the secret over a private stdin channel. macOS
  # `security -w` insists on a terminal, so the system `expect` utility supplies
  # a PTY, disables its log, and relays the password only after seeing the
  # prompt. The credential never appears in argv, process listings, or events.
  defp run_macos_with_input(expect, executable, reference, secret) do
    ready = "BEAM_AGENT_KEYRING_READY"

    env = [
      {~c"BEAM_AGENT_CREDENTIAL_EXECUTABLE", String.to_charlist(executable)},
      {~c"BEAM_AGENT_CREDENTIAL_REFERENCE", String.to_charlist(reference)}
      | port_env()
    ]

    port =
      Port.open({:spawn_executable, expect}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        :use_stdio,
        args: ["-N", "-n", "-c", @expect_script],
        env: env
      ])

    await_ready(port, secret, ready, System.monotonic_time(:millisecond) + @command_timeout)
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp run_with_input(executable, args, secret) do
    port =
      Port.open({:spawn_executable, executable}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        :use_stdio,
        args: args,
        env: port_env()
      ])

    true = Port.command(port, [secret, "\n"])
    await_port(port, [], System.monotonic_time(:millisecond) + @command_timeout)
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp await_ready(port, secret, marker, deadline, output \\ []) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} ->
        output = [data | output]

        if output |> Enum.reverse() |> IO.iodata_to_binary() |> String.contains?(marker) do
          true = Port.command(port, [secret, "\n"])
          await_port(port, output, deadline)
        else
          await_ready(port, secret, marker, deadline, output)
        end

      {^port, {:exit_status, status}} ->
        {:error, {status, "credential helper exited before accepting input"}}
    after
      remaining ->
        Port.close(port)
        {:error, :credential_helper_timeout}
    end
  end

  defp await_port(port, output, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} -> await_port(port, [data | output], deadline)
      {^port, {:exit_status, 0}} -> {:ok, output |> Enum.reverse() |> IO.iodata_to_binary()}
      {^port, {:exit_status, status}} -> {:error, {status, "credential helper failed"}}
    after
      remaining ->
        Port.close(port)
        {:error, :credential_helper_timeout}
    end
  end

  defp sanitized_env do
    System.get_env()
    |> Enum.reject(fn {name, _value} ->
      normalized = String.upcase(name)
      String.contains?(normalized, "KEY") or String.contains?(normalized, "TOKEN")
    end)
  end

  defp port_env do
    sanitized_env()
    |> Enum.map(fn {name, value} -> {String.to_charlist(name), String.to_charlist(value)} end)
  end
end
