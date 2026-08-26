defmodule Mix.Tasks.BeamAgent.Demo do
  use Mix.Task

  @shortdoc "Run the deterministic multi-step agent/subagent demonstration"

  @impl true
  def run(_args) do
    Mix.Task.run("app.start")

    {:ok, session_id} = BeamAgent.start_session()
    {:ok, answer} = BeamAgent.ask(session_id, "Calculate 2 + 3 and ask a subagent to verify it.")
    {:ok, events} = BeamAgent.events(session_id)
    {:ok, path} = BeamAgent.event_log_path(session_id)

    Mix.shell().info("session: #{session_id}")
    Mix.shell().info("answer: #{answer}")
    Mix.shell().info("durable events: #{length(events)} at #{path}")
  end
end
