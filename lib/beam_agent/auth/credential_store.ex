defmodule BeamAgent.Auth.CredentialStore do
  @moduledoc "Supervised broker for opaque credentials stored in an OS keyring."
  use GenServer

  @name __MODULE__

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, @name))
  end

  def put(reference, credential, server \\ @name)
      when is_binary(reference) and is_map(credential) do
    GenServer.call(server, {:put, reference, credential}, :infinity)
  end

  def resolve(reference, server \\ @name) when is_binary(reference) do
    GenServer.call(server, {:resolve, reference}, :infinity)
  end

  def metadata(reference, server \\ @name) when is_binary(reference) do
    GenServer.call(server, {:metadata, reference}, :infinity)
  end

  def delete(reference, server \\ @name) when is_binary(reference) do
    GenServer.call(server, {:delete, reference}, :infinity)
  end

  def subscribe(server \\ @name) do
    GenServer.call(server, {:subscribe, self()})
  end

  @impl true
  def init(opts) do
    backend =
      Keyword.get(opts, :backend) ||
        Application.get_env(:beam_agent, :credential_keyring, BeamAgent.Auth.Keyring.Native)

    with {:ok, backend_state} <- backend.init(opts) do
      {:ok,
       %{
         backend: backend,
         backend_state: backend_state,
         refresher:
           Keyword.get(opts, :refresher) ||
             Application.get_env(:beam_agent, :oauth_token_refresher, BeamAgent.Auth.OAuthDevice),
         subscribers: %{}
       }}
    end
  end

  @impl true
  def handle_call({:put, reference, credential}, _from, state) do
    with :ok <- validate_reference(reference),
         {:ok, encoded} <- encode(credential),
         {:ok, backend_state} <- state.backend.put(reference, encoded, state.backend_state) do
      {:reply, :ok, %{state | backend_state: backend_state}}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:resolve, reference}, _from, state) do
    {result, state} = fetch_credential(reference, state)

    case result do
      {:ok, credential} ->
        {result, state} = resolve_token(reference, credential, state)
        {:reply, result, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:metadata, reference}, _from, state) do
    {result, state} = fetch_credential(reference, state)

    metadata =
      with {:ok, credential} <- result do
        {:ok,
         %{
           type: credential["type"],
           provider: credential["provider"],
           expires_at: credential["expires_at"]
         }}
      end

    {:reply, metadata, state}
  end

  def handle_call({:delete, reference}, _from, state) do
    case state.backend.delete(reference, state.backend_state) do
      {:ok, backend_state} -> {:reply, :ok, %{state | backend_state: backend_state}}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:subscribe, pid}, _from, state) when is_pid(pid) do
    state =
      if Map.has_key?(state.subscribers, pid) do
        state
      else
        put_in(state.subscribers[pid], Process.monitor(pid))
      end

    {:reply, :ok, state}
  end

  @impl true
  def handle_info({:DOWN, monitor, :process, pid, _reason}, state) do
    case state.subscribers[pid] do
      ^monitor -> {:noreply, update_in(state.subscribers, &Map.delete(&1, pid))}
      _other -> {:noreply, state}
    end
  end

  defp fetch_credential(reference, state) do
    case state.backend.fetch(reference, state.backend_state) do
      {{:ok, encoded}, backend_state} ->
        result =
          case JSON.decode(encoded) do
            {:ok, credential} when is_map(credential) -> {:ok, credential}
            _ -> {:error, :invalid_stored_credential}
          end

        {result, %{state | backend_state: backend_state}}

      {{:error, reason}, backend_state} ->
        {{:error, reason}, %{state | backend_state: backend_state}}
    end
  end

  defp token(%{"type" => "api_key", "secret" => secret})
       when is_binary(secret) and secret != "",
       do: {:ok, secret}

  defp token(%{"type" => "oauth", "access_token" => token} = credential)
       when is_binary(token) and token != "" do
    if expired?(credential), do: {:error, :oauth_token_expired}, else: {:ok, token}
  end

  defp token(_credential), do: {:error, :invalid_stored_credential}

  defp resolve_token(reference, credential, state) do
    case token(credential) do
      {:ok, value} ->
        {{:ok, value}, state}

      {:error, :oauth_token_expired} ->
        refresh(reference, credential, state)

      {:error, reason} ->
        {{:error, reason}, state}
    end
  end

  defp refresh(reference, %{"refresh_token" => refresh_token} = credential, state)
       when is_binary(refresh_token) and refresh_token != "" do
    with {:ok, refreshed} <- state.refresher.refresh(credential),
         {:ok, token} <- token(refreshed),
         {:ok, encoded} <- encode(refreshed),
         {:ok, backend_state} <- state.backend.put(reference, encoded, state.backend_state) do
      state = %{state | backend_state: backend_state}

      emit(state, :auth_token_refreshed, %{
        credential_reference: reference,
        provider: refreshed["provider"],
        expires_at: refreshed["expires_at"]
      })

      {{:ok, token}, state}
    else
      {:error, reason} -> {{:error, {:oauth_refresh_failed, reason}}, state}
    end
  end

  defp refresh(_reference, _credential, state),
    do: {{:error, :oauth_token_expired}, state}

  defp emit(state, type, data) do
    event = %{type: type, data: data}
    Enum.each(Map.keys(state.subscribers), &send(&1, {:beam_agent_auth, self(), event}))
  end

  defp expired?(%{"expires_at" => nil}), do: false
  defp expired?(%{"expires_at" => expires}) when is_integer(expires), do: expires <= now() + 30
  defp expired?(_credential), do: false

  defp encode(credential) do
    {:ok, JSON.encode!(credential)}
  rescue
    error -> {:error, {:invalid_credential, Exception.message(error)}}
  end

  defp validate_reference(reference) do
    if Regex.match?(~r/\Akeychain:\/\/beam-agent\/[a-zA-Z0-9._-]{1,64}\z/, reference),
      do: :ok,
      else: {:error, :invalid_credential_reference}
  end

  defp now, do: System.system_time(:second)
end
