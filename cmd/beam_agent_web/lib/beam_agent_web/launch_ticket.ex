defmodule BeamAgentWeb.LaunchTicket do
  @moduledoc "Short-lived, single-use browser bootstrap. Never accepts the runtime bearer token."
  use GenServer
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  def issue(ticket, ttl \\ 90_000), do: GenServer.call(__MODULE__, {:issue, ticket, ttl})
  def consume(ticket) when is_binary(ticket), do: GenServer.call(__MODULE__, {:consume, ticket})
  def consume(_), do: false

  def init(_) do
    ticket = System.get_env("BEAM_AGENT_DESK_LAUNCH_TICKET")
    System.delete_env("BEAM_AGENT_DESK_LAUNCH_TICKET")
    {:ok, state(ticket, 90_000)}
  end

  def handle_call({:issue, ticket, ttl}, _, _state), do: {:reply, :ok, state(ticket, ttl)}

  def handle_call({:consume, supplied}, _, state) do
    valid =
      state != nil and System.monotonic_time(:millisecond) < state.expires and
        Plug.Crypto.secure_compare(:crypto.hash(:sha256, supplied), state.hash)

    {:reply, valid, if(valid, do: nil, else: state)}
  end

  defp state(ticket, ttl) when is_binary(ticket) and byte_size(ticket) >= 32,
    do: %{hash: :crypto.hash(:sha256, ticket), expires: System.monotonic_time(:millisecond) + ttl}

  defp state(_, _), do: nil
end
