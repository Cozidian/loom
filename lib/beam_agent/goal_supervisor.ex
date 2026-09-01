defmodule BeamAgent.GoalSupervisor do
  @moduledoc "One ephemeral goal boundary backed initially by a durable root session."
  use Supervisor

  @shutdown_timeout_ms 2_000

  alias BeamAgent.{Goal, Names, SessionSupervisor}

  alias BeamAgent.Goal.{
    BudgetManager,
    CapabilityManager,
    DelegationManager,
    EventHub,
    ModelLease,
    OrganizationManager,
    ProgressMonitor,
    ProviderBidCoordinator,
    ResourceSupervisor,
    SecretBroker
  }

  alias BeamAgent.MCP.Registry

  def start_link(opts) do
    goal_id = Keyword.fetch!(opts, :goal_id)
    Supervisor.start_link(__MODULE__, opts, name: Names.via(:goal_supervisor, goal_id))
  end

  def child_spec(opts) do
    goal_id = Keyword.fetch!(opts, :goal_id)

    %{
      id: {__MODULE__, goal_id},
      start: {__MODULE__, :start_link, [opts]},
      restart: :transient,
      shutdown: @shutdown_timeout_ms,
      type: :supervisor
    }
  end

  @impl true
  def init(opts) do
    goal_id = Keyword.fetch!(opts, :goal_id)

    session =
      {SessionSupervisor, opts}
      |> Supervisor.child_spec(restart: :permanent)

    Supervisor.init(
      [
        {Goal, opts},
        {EventHub, opts},
        {BudgetManager, opts},
        {CapabilityManager, opts},
        {DelegationManager, opts},
        {OrganizationManager, opts},
        {SecretBroker, opts},
        {ModelLease, opts},
        {Task.Supervisor, name: Names.via(:provider_bid_supervisor, goal_id)},
        {ProviderBidCoordinator, opts},
        {ResourceSupervisor, opts},
        {Task.Supervisor, name: Names.via(:goal_verification_supervisor, goal_id)},
        {Registry, opts},
        session,
        {ProgressMonitor, opts}
      ],
      strategy: :rest_for_one
    )
  end
end
