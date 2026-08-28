defmodule BeamAgent.Auth.Session do
  @moduledoc "Ephemeral, supervised OAuth device-login process."
  use GenServer, restart: :temporary

  alias BeamAgent.Auth.CredentialStore

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
  def await(session), do: GenServer.call(session, :await, :infinity)
  def cancel(session), do: GenServer.stop(session, :cancelled)

  @impl true
  def init(opts) do
    owner = Keyword.fetch!(opts, :owner)

    state = %{
      owner: owner,
      owner_monitor: Process.monitor(owner),
      reference: Keyword.fetch!(opts, :reference),
      provider: Keyword.fetch!(opts, :provider),
      adapter: Keyword.get(opts, :adapter, BeamAgent.Auth.OAuthDevice),
      adapter_options: opts |> Map.new() |> Map.put(:provider, Keyword.fetch!(opts, :provider)),
      credential_store: Keyword.get(opts, :credential_store, CredentialStore),
      poll_state: nil,
      result: nil,
      waiters: []
    }

    emit(state, :auth_started, %{provider: state.provider, method: :device_code})
    {:ok, state, {:continue, :authorize}}
  end

  @impl true
  def handle_continue(:authorize, state) do
    case state.adapter.authorize(state.adapter_options) do
      {:ok, authorization} ->
        emit(state, :auth_user_action_required, authorization.public)
        Process.send_after(self(), :poll, authorization.poll_after_ms)
        {:noreply, %{state | poll_state: authorization.poll_state}}

      {:error, reason} ->
        finish({:error, reason}, state)
    end
  end

  @impl true
  def handle_call(:await, _from, %{result: result} = state) when not is_nil(result) do
    {:stop, :normal, result, state}
  end

  def handle_call(:await, from, state), do: {:noreply, %{state | waiters: [from | state.waiters]}}

  @impl true
  def handle_info(:poll, state) do
    case state.adapter.poll(state.poll_state) do
      {:pending, poll_state, after_ms} ->
        Process.send_after(self(), :poll, after_ms)
        {:noreply, %{state | poll_state: poll_state}}

      {:ok, credential} ->
        case CredentialStore.put(state.reference, credential, state.credential_store) do
          :ok -> finish({:ok, public_result(state, credential)}, state)
          {:error, reason} -> finish({:error, reason}, state)
        end

      {:error, reason} ->
        finish({:error, reason}, state)
    end
  end

  def handle_info({:DOWN, monitor, :process, owner, reason}, state)
      when monitor == state.owner_monitor and owner == state.owner do
    {:stop, {:owner_exited, reason}, state}
  end

  defp finish(result, state) do
    case result do
      {:ok, public} -> emit(state, :auth_completed, public)
      {:error, reason} -> emit(state, :auth_failed, %{reason: inspect(reason)})
    end

    Enum.each(state.waiters, &GenServer.reply(&1, result))

    if state.waiters == [] do
      {:noreply, %{state | result: result}}
    else
      {:stop, :normal, %{state | result: result, waiters: []}}
    end
  end

  defp public_result(state, credential) do
    %{
      provider: state.provider,
      credential_reference: state.reference,
      credential_type: credential["type"],
      expires_at: credential["expires_at"]
    }
  end

  defp emit(state, type, data) do
    send(state.owner, {:beam_agent_auth, self(), %{type: type, data: data}})
  end
end
