defmodule BeamAgent.Auth do
  @moduledoc "Public provider authentication and credential-broker API."

  alias BeamAgent.Auth.{CodexSession, CredentialStore, Session, SessionSupervisor}

  def default_reference(profile) when is_binary(profile) do
    if Regex.match?(~r/\A[a-zA-Z0-9][a-zA-Z0-9._-]{0,63}\z/, profile) do
      {:ok, "keychain://beam-agent/#{profile}"}
    else
      {:error, :invalid_profile_name}
    end
  end

  def login_api_key(profile, provider, secret, opts \\ [])

  def login_api_key(profile, provider, secret, opts)
      when is_binary(secret) and secret != "" do
    with {:ok, reference} <- default_reference(profile),
         :ok <-
           CredentialStore.put(
             reference,
             %{
               "version" => 1,
               "type" => "api_key",
               "provider" => to_string(provider),
               "secret" => secret,
               "expires_at" => nil
             },
             Keyword.get(opts, :credential_store, CredentialStore)
           ) do
      {:ok, reference}
    end
  end

  def login_api_key(_profile, _provider, _secret, _opts), do: {:error, :empty_api_key}

  def start_device_login(profile, provider, options \\ []) do
    with {:ok, reference} <- default_reference(profile) do
      child =
        {Session,
         options
         |> Keyword.put(:owner, Keyword.get(options, :owner, self()))
         |> Keyword.put(:reference, reference)
         |> Keyword.put(:provider, provider)}

      DynamicSupervisor.start_child(SessionSupervisor, child)
    end
  end

  def start_chatgpt_login(profile, provider \\ :openai, options \\ []) do
    with {:ok, _reference} <- default_reference(profile) do
      child =
        {CodexSession,
         options
         |> Keyword.put(:owner, Keyword.get(options, :owner, self()))
         |> Keyword.put(:provider, provider)}

      DynamicSupervisor.start_child(SessionSupervisor, child)
    end
  end

  def await(session), do: Session.await(session)
  def cancel(session), do: Session.cancel(session)

  def resolve(reference), do: CredentialStore.resolve(reference)
  def subscribe, do: CredentialStore.subscribe()

  def logout(profile) do
    with {:ok, reference} <- default_reference(profile), do: CredentialStore.delete(reference)
  end
end
