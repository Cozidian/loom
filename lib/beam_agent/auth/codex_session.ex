defmodule BeamAgent.Auth.CodexSession do
  @moduledoc """
  Ephemeral browser-login process backed by OpenAI's Codex App Server.

  Codex owns OAuth credentials and refresh. This process owns only the login
  ceremony and exposes safe account metadata to the CLI/TUI.
  """
  use GenServer, restart: :temporary

  alias BeamAgent.CodexAppServer
  alias BeamAgent.CodexAppServer.Client

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    owner = Keyword.fetch!(opts, :owner)

    state = %{
      owner: owner,
      owner_monitor: Process.monitor(owner),
      provider: Keyword.get(opts, :provider, :openai),
      client_module: Keyword.get(opts, :codex_client, Client),
      client_options: Keyword.get(opts, :codex_client_options, []),
      client: nil,
      login_id: nil,
      result: nil,
      waiters: []
    }

    emit(state, :auth_started, %{provider: state.provider, method: :chatgpt})
    {:ok, state, {:continue, :start_login}}
  end

  @impl true
  def handle_continue(:start_login, state) do
    opts = Keyword.put_new(state.client_options, :owner, self())

    case state.client_module.start_link(opts) do
      {:ok, client} ->
        continue_login(%{state | client: client})

      {:error, reason} ->
        finish({:error, reason}, state)
    end
  end

  defp continue_login(state) do
    with :ok <- CodexAppServer.initialize(state.client, state.client_module),
         {:ok, result} <-
           state.client_module.request(state.client, "account/login/start", %{
             "type" => "chatgpt",
             "useHostedLoginSuccessPage" => true,
             "appBrand" => "chatgpt"
           }),
         login_id when is_binary(login_id) <- result["loginId"],
         auth_url when is_binary(auth_url) <- result["authUrl"] do
      state = %{state | login_id: login_id}

      emit(state, :auth_user_action_required, %{
        verification_uri: auth_url,
        verification_uri_complete: auth_url,
        user_code: nil,
        login_id: login_id
      })

      {:noreply, state}
    else
      nil -> finish({:error, :invalid_chatgpt_login_response}, state)
      {:error, reason} -> finish({:error, reason}, state)
    end
  end

  @impl true
  def handle_call(:await, _from, %{result: result} = state) when not is_nil(result) do
    {:stop, :normal, result, state}
  end

  def handle_call(:await, from, state), do: {:noreply, %{state | waiters: [from | state.waiters]}}

  @impl true
  def handle_info(
        {:codex_app_server, client,
         {:notification,
          %{
            "method" => "account/login/completed",
            "params" => %{"loginId" => login_id, "success" => true}
          }}},
        %{client: client, login_id: login_id} = state
      ) do
    case state.client_module.request(client, "account/read", %{"refreshToken" => false}) do
      {:ok, %{"account" => %{"type" => "chatgpt"}} = account} ->
        finish({:ok, public_result(state, account)}, state)

      {:ok, account} ->
        finish({:error, {:invalid_codex_account, account}}, state)

      {:error, reason} ->
        finish({:error, reason}, state)
    end
  end

  def handle_info(
        {:codex_app_server, client,
         {:notification,
          %{
            "method" => "account/login/completed",
            "params" => %{"loginId" => login_id, "success" => false} = params
          }}},
        %{client: client, login_id: login_id} = state
      ) do
    finish({:error, {:chatgpt_login_failed, params["error"]}}, state)
  end

  def handle_info({:codex_app_server, client, {:exit, reason}}, %{client: client} = state) do
    finish({:error, reason}, %{state | client: nil})
  end

  def handle_info({:codex_app_server, _client, _event}, state), do: {:noreply, state}

  def handle_info({:DOWN, monitor, :process, owner, reason}, state)
      when monitor == state.owner_monitor and owner == state.owner do
    {:stop, {:owner_exited, reason}, state}
  end

  @impl true
  def terminate(_reason, state) do
    if is_pid(state.client), do: state.client_module.stop(state.client)
    :ok
  end

  defp finish(result, state) do
    case result do
      {:ok, public} -> emit(state, :auth_completed, public)
      {:error, reason} -> emit(state, :auth_failed, %{reason: inspect(reason)})
    end

    had_waiters? = state.waiters != []
    Enum.each(state.waiters, &GenServer.reply(&1, result))
    state = %{state | result: result, waiters: []}

    if had_waiters?, do: {:stop, :normal, state}, else: {:noreply, state}
  end

  defp public_result(state, %{"account" => %{"type" => "chatgpt"} = account}) do
    %{
      provider: state.provider,
      credential_reference: nil,
      credential_type: "chatgpt",
      auth: %{"type" => "chatgpt", "transport" => "codex_app_server"},
      plan_type: account["planType"],
      email: account["email"]
    }
  end

  defp emit(state, type, data) do
    send(state.owner, {:beam_agent_auth, self(), %{type: type, data: data}})
  end
end
