defmodule BeamAgent.AuthTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias BeamAgent.Auth
  alias BeamAgent.Auth.CredentialStore
  alias BeamAgent.CLI.Config

  defmodule FakeDeviceAdapter do
    @behaviour BeamAgent.Auth.DeviceAdapter

    @impl true
    def authorize(_options) do
      {:ok,
       %{
         public: %{
           verification_uri: "https://login.example/device",
           verification_uri_complete: nil,
           user_code: "ABCD-EFGH",
           expires_in: 600
         },
         poll_state: :first,
         poll_after_ms: 1
       }}
    end

    @impl true
    def poll(:first), do: {:pending, :second, 1}

    def poll(:second) do
      {:ok,
       %{
         "version" => 1,
         "type" => "oauth",
         "provider" => "openai",
         "access_token" => "oauth-access-token",
         "refresh_token" => "oauth-refresh-token",
         "expires_at" => System.system_time(:second) + 3_600
       }}
    end
  end

  defmodule FakeTokenRefresher do
    @behaviour BeamAgent.Auth.TokenRefresher

    @impl true
    def refresh(credential) do
      {:ok,
       credential
       |> Map.put("access_token", "refreshed-access-token")
       |> Map.put("expires_at", System.system_time(:second) + 3_600)}
    end
  end

  defmodule FakeCodexClient do
    def start_link(opts) do
      Agent.start_link(fn ->
        %{
          owner: Keyword.fetch!(opts, :owner),
          test_pid: Keyword.fetch!(opts, :test_pid)
        }
      end)
    end

    def request(_client, "initialize", _params), do: {:ok, %{}}

    def request(client, "account/login/start", params) do
      state = Agent.get(client, & &1)
      send(state.test_pid, {:fake_codex_login_started, client, params})

      {:ok,
       %{
         "loginId" => "login-test",
         "authUrl" => "https://auth.openai.com/beam-agent-test"
       }}
    end

    def request(_client, "account/read", %{"refreshToken" => false}) do
      {:ok,
       %{
         "account" => %{
           "type" => "chatgpt",
           "planType" => "plus",
           "email" => "person@example.test"
         }
       }}
    end

    def notify(_client, "initialized", %{}), do: :ok
    def stop(client), do: Agent.stop(client)
  end

  setup do
    profile = "auth-test-#{System.unique_integer([:positive])}"
    on_exit(fn -> Auth.logout(profile) end)
    %{profile: profile}
  end

  test "API keys resolve through opaque keyring references", %{profile: profile} do
    assert {:ok, reference} = Auth.login_api_key(profile, :openai, "secret-api-key")
    assert reference == "keychain://beam-agent/#{profile}"
    assert {:ok, "secret-api-key"} = Auth.resolve(reference)

    assert {:ok, metadata} = CredentialStore.metadata(reference)
    assert metadata.type == "api_key"
    assert metadata.provider == "openai"

    assert :ok = Auth.logout(profile)
    assert {:error, :credential_not_found} = Auth.resolve(reference)
  end

  test "device authorization is supervised and emits only safe lifecycle data", %{
    profile: profile
  } do
    assert {:ok, session} =
             Auth.start_device_login(profile, :openai,
               adapter: FakeDeviceAdapter,
               device_endpoint: "https://login.example/device/code",
               token_endpoint: "https://login.example/oauth/token",
               client_id: "beam-agent-test",
               owner: self()
             )

    assert_receive {:beam_agent_auth, ^session, %{type: :auth_started}}

    assert_receive {:beam_agent_auth, ^session,
                    %{
                      type: :auth_user_action_required,
                      data: %{user_code: "ABCD-EFGH"} = action
                    }}

    refute inspect(action) =~ "oauth-access-token"
    assert {:ok, result} = Auth.await(session)
    assert result.credential_reference == "keychain://beam-agent/#{profile}"
    assert {:ok, "oauth-access-token"} = Auth.resolve(result.credential_reference)
  end

  test "ChatGPT browser authorization returns an app-server auth marker without tokens", %{
    profile: profile
  } do
    assert {:ok, session} =
             Auth.start_chatgpt_login(profile, :openai,
               codex_client: FakeCodexClient,
               codex_client_options: [test_pid: self()],
               owner: self()
             )

    assert_receive {:beam_agent_auth, ^session, %{type: :auth_started}}

    assert_receive {:beam_agent_auth, ^session,
                    %{
                      type: :auth_user_action_required,
                      data: %{verification_uri: verification_uri, user_code: nil}
                    }}

    assert verification_uri =~ "auth.openai.com"
    refute inspect(verification_uri) =~ "access_token"

    assert_receive {:fake_codex_login_started, client,
                    %{"type" => "chatgpt", "useHostedLoginSuccessPage" => true}}

    send(
      session,
      {:codex_app_server, client,
       {:notification,
        %{
          "method" => "account/login/completed",
          "params" => %{"loginId" => "login-test", "success" => true}
        }}}
    )

    assert_receive {:beam_agent_auth, ^session, %{type: :auth_completed}}
    assert {:ok, result} = Auth.await(session)
    assert result.credential_reference == nil
    assert result.auth == %{"type" => "chatgpt", "transport" => "codex_app_server"}
    assert result.plan_type == "plus"
    refute inspect(result) =~ "access_token"
  end

  test "expired OAuth access tokens refresh inside the credential broker", %{
    profile: profile
  } do
    name = {:global, {:credential_store, make_ref()}}

    store =
      start_supervised!(
        {CredentialStore,
         name: name, backend: BeamAgent.Auth.Keyring.Memory, refresher: FakeTokenRefresher}
      )

    reference = "keychain://beam-agent/#{profile}"

    assert :ok =
             CredentialStore.put(
               reference,
               %{
                 "version" => 1,
                 "type" => "oauth",
                 "provider" => "openai",
                 "access_token" => "expired-access-token",
                 "refresh_token" => "refresh-token",
                 "expires_at" => System.system_time(:second) - 1
               },
               store
             )

    assert :ok = CredentialStore.subscribe(store)
    assert {:ok, "refreshed-access-token"} = CredentialStore.resolve(reference, store)

    assert_receive {:beam_agent_auth, ^store,
                    %{
                      type: :auth_token_refreshed,
                      data: %{credential_reference: ^reference, provider: "openai"}
                    }}
  end

  test "CLI stores API keys outside configuration", %{profile: profile} do
    root = Path.join(System.tmp_dir!(), "beam-agent-auth-#{System.unique_integer([:positive])}")
    config_path = Path.join(root, "config.json")
    data_dir = Path.join(root, "sessions")

    on_exit(fn -> File.rm_rf(root) end)

    {:ok, provider_profile} =
      Config.profile("openai", "gpt-test", "https://api.openai.com/v1", "OPENAI_API_KEY")

    config =
      Config.defaults()
      |> Map.put("active_profile", profile)
      |> Map.put("profiles", %{profile => provider_profile})
      |> Map.put("data_dir", data_dir)

    assert {:ok, ^config_path} = Config.write(config, config_path)

    output =
      capture_io([input: "super-secret-value\n"], fn ->
        assert BeamAgent.CLI.run([
                 "--config",
                 config_path,
                 "auth",
                 "login",
                 profile,
                 "--api-key-stdin"
               ]) == 0
      end)

    assert output =~ "operating-system keyring"
    refute File.read!(config_path) =~ "super-secret-value"

    assert {:ok, stored} = Config.load(config_path)

    assert get_in(stored, ["profiles", profile, "credential_ref"]) ==
             "keychain://beam-agent/#{profile}"

    assert {:ok, "super-secret-value"} = Auth.resolve("keychain://beam-agent/#{profile}")
  end

  test "ChatGPT auth metadata survives config and model-endpoint projection", %{
    profile: profile
  } do
    {:ok, provider_profile} =
      Config.profile("openai", "gpt-test", "https://api.openai.com/v1", "OPENAI_API_KEY")

    config =
      Config.defaults()
      |> Map.put("active_profile", profile)
      |> Map.put("profiles", %{profile => provider_profile})

    auth = %{"type" => "chatgpt", "transport" => "codex_app_server"}
    assert {:ok, config} = Config.put_profile_auth(config, profile, nil, auth)
    assert {:ok, runtime} = Config.runtime(config, profile)
    assert runtime["auth"] == auth

    [endpoint] = Config.model_endpoints(config, runtime)
    assert endpoint[:auth] == auth
    refute endpoint[:credential_ref]
  end

  test "ChatGPT profile logout disconnects BeamAgent without invoking shared account logout", %{
    profile: profile
  } do
    root = Path.join(System.tmp_dir!(), "beam-agent-chatgpt-config-#{System.unique_integer()}")
    config_path = Path.join(root, "config.json")
    on_exit(fn -> File.rm_rf(root) end)

    {:ok, provider_profile} =
      Config.profile("openai", "gpt-test", "https://api.openai.com/v1", "OPENAI_API_KEY")

    auth = %{"type" => "chatgpt", "transport" => "codex_app_server"}

    config =
      Config.defaults()
      |> Map.put("active_profile", profile)
      |> Map.put("profiles", %{profile => provider_profile})

    assert {:ok, config} = Config.put_profile_auth(config, profile, nil, auth)
    assert {:ok, ^config_path} = Config.write(config, config_path)

    output =
      capture_io(fn ->
        assert BeamAgent.CLI.run(["--config", config_path, "auth", "logout", profile]) == 0
      end)

    assert output =~ "shared Codex login remains available"
    assert {:ok, stored} = Config.load(config_path)
    assert get_in(stored, ["profiles", profile, "auth"]) == nil
  end
end
