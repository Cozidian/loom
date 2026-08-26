defmodule BeamAgent.Tools.SpawnSubagent do
  @moduledoc false
  @behaviour BeamAgent.Tool

  alias BeamAgent.Session.EventLog

  @impl true
  def name, do: "spawn_subagent"

  @impl true
  def description,
    do: "Spawn a supervised child agent with its own durable session and await its answer."

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{prompt: %{type: "string"}},
      required: ["prompt"]
    }
  end

  @impl true
  def access, do: :delegate

  @impl true
  def execute(%{"prompt" => prompt}, context) when is_binary(prompt) and prompt != "" do
    opts = [
      provider: context.provider,
      provider_profile: context.provider_profile,
      provider_options: context.provider_options,
      strategy: context.strategy,
      data_dir: context.data_dir,
      workspace_root: context.workspace_root,
      approval_policy: context.approval_policy,
      approval_handler: context.approval_handler,
      context_window_tokens: context.context_window_tokens,
      compaction_threshold_percent: context.compaction_threshold_percent
    ]

    with {:ok, child_id} <- BeamAgent.spawn_subagent(context.session_id, opts),
         {:ok, _event} <-
           EventLog.append(context.session_id, :subagent_spawned, %{
             "child_session_id" => child_id
           }),
         {:ok, answer} <- BeamAgent.ask(child_id, prompt) do
      {:ok, JSON.encode!(%{child_session_id: child_id, answer: answer})}
    end
  end

  def execute(_arguments, _context), do: {:error, :expected_non_empty_prompt}
end
