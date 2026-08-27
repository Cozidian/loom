defmodule BeamAgent.RuntimeEventViewTest do
  use ExUnit.Case, async: false

  alias BeamAgent.RuntimeEventView

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "beam-agent-event-view-test-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf(root) end)
    %{data_dir: root}
  end

  test "goal replay is public and redacted by default while internal replay is explicit",
       context do
    secret = "private-prompt-#{System.unique_integer([:positive])}"
    workspace = Path.join(context.data_dir, "workspace-#{secret}")
    File.mkdir_p!(workspace)

    {:ok, session_id} =
      BeamAgent.start_session(
        data_dir: context.data_dir,
        workspace_root: workspace,
        provider: :echo
      )

    assert {:ok, answer} = BeamAgent.ask(session_id, secret)
    assert answer =~ secret

    assert {:ok, public_events} = BeamAgent.goal_events(session_id)
    public_json = JSON.encode!(public_events)

    refute public_json =~ secret
    refute public_json =~ workspace
    assert Enum.all?(public_events, &(&1.visibility == :public))

    public_user = Enum.find(public_events, &(&1.payload.type == "user_message"))
    assert public_user.redacted?
    assert public_user.payload.data["content"]["redacted"]

    public_assistant = Enum.find(public_events, &(&1.payload.type == "assistant_message"))
    assert public_assistant.payload.data["content"]["redacted"]

    assert {:ok, internal_events} = BeamAgent.goal_events(session_id, view: :internal)
    internal_user = Enum.find(internal_events, &(&1.payload.type == "user_message"))
    assert internal_user.payload.data["content"] == secret
    refute Map.has_key?(internal_user, :visibility)

    assert {:ok, canonical_events} = BeamAgent.events(session_id)
    assert JSON.encode!(canonical_events) =~ secret
  end

  test "public subscriptions redact live values and internal subscriptions retain them",
       context do
    {:ok, session_id} = BeamAgent.start_session(data_dir: context.data_dir, provider: :echo)
    assert :ok = BeamAgent.subscribe_goal(session_id)

    public_secret = "public-live-secret-#{System.unique_integer([:positive])}"
    assert {:ok, _answer} = BeamAgent.ask(session_id, public_secret)

    assert_receive {:beam_agent_runtime_event,
                    %{
                      visibility: :public,
                      payload: %{
                        type: "user_message",
                        data: %{"content" => %{"redacted" => true}}
                      }
                    }}

    assert :ok = BeamAgent.unsubscribe_goal(session_id)
    assert :ok = BeamAgent.subscribe_goal(session_id, view: :internal)

    internal_secret = "internal-live-secret-#{System.unique_integer([:positive])}"
    assert {:ok, _answer} = BeamAgent.ask(session_id, internal_secret)

    assert_receive {:beam_agent_runtime_event,
                    %{
                      payload: %{
                        type: "user_message",
                        data: %{"content" => ^internal_secret}
                      }
                    }}
  end

  test "the public projection fails closed for tool data, errors, and unknown fields" do
    event = %{
      type: :runtime_event,
      payload: %{
        type: "tool_result",
        data: %{
          "name" => "run_command",
          "tool_call_id" => "call-1",
          "is_error" => true,
          "arguments" => %{"command" => "SECRET_COMMAND"},
          "content" => "SECRET_OUTPUT",
          "error" => %{"code" => "SECRET_CODE", "detail" => "SECRET_DETAIL"},
          "future_provider_field" => "SECRET_FUTURE_VALUE"
        }
      }
    }

    public = RuntimeEventView.project(event, :public)
    encoded = JSON.encode!(public)

    assert public.payload.data["name"] == "run_command"
    assert public.payload.data["tool_call_id"] == "call-1"
    assert public.payload.data["is_error"]
    assert public.payload.data["arguments"]["redacted"]
    assert public.payload.data["content"]["redacted"]
    assert public.payload.data["error"]["redacted"]
    assert public.payload.data["future_provider_field"]["redacted"]
    refute encoded =~ "SECRET_"
    assert RuntimeEventView.project(event, :internal) == event
  end

  test "public checkpoint summaries preserve event types and numeric usage only" do
    event = %{
      payload: %{
        type: "model_response_checkpoint",
        data: %{
          "events" => [
            %{"type" => "text_delta", "delta" => "SECRET_TEXT"},
            %{
              "type" => "usage",
              "usage" => %{"output_tokens" => 3, "provider_note" => "SECRET_NOTE"}
            }
          ]
        }
      }
    }

    public = RuntimeEventView.project(event, :public)
    [text_delta, usage] = public.payload.data["events"]

    assert text_delta["type"] == "text_delta"
    assert text_delta["delta"]["redacted"]
    assert usage["usage"]["output_tokens"] == 3
    assert usage["usage"]["provider_note"]["redacted"]
    refute JSON.encode!(public) =~ "SECRET_"
  end

  test "public routing evidence exposes aggregate metrics without outcome content" do
    event = %{
      payload: %{
        type: "model_route_selected",
        data: %{
          "selected_endpoint_id" => "local",
          "evidence" => %{
            "mode" => "shadow",
            "state" => "ready",
            "recommended_endpoint_id" => "remote",
            "minimum_verified_samples" => 5,
            "endpoints" => [
              %{
                "endpoint_id" => "remote",
                "verified_samples" => 8,
                "verified_pass_rate" => 0.875,
                "average_latency_ms" => 420
              }
            ]
          }
        }
      }
    }

    public = RuntimeEventView.project(event, :public)
    evidence = public.payload.data["evidence"]
    assert evidence["recommended_endpoint_id"] == "remote"
    assert hd(evidence["endpoints"])["verified_samples"] == 8
    refute public.redacted?
  end
end
