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
    {:ok, add(%{}, ticket, 90_000)}
  end

  def handle_call({:issue, ticket, ttl}, _, tickets), do: {:reply, :ok, add(tickets, ticket, ttl)}

  def handle_call({:consume, supplied}, _, tickets) do
    hash = :crypto.hash(:sha256, supplied)
    {expires, remaining} = Map.pop(tickets, hash)
    {:reply, is_integer(expires) and System.monotonic_time(:millisecond) < expires, remaining}
  end

  defp add(tickets, ticket, ttl) when is_binary(ticket) and byte_size(ticket) >= 32 do
    now = System.monotonic_time(:millisecond)

    tickets =
      tickets
      |> Enum.filter(fn {_, expiry} -> expiry > now end)
      |> Enum.sort_by(&elem(&1, 1), :desc)
      |> Enum.take(31)
      |> Map.new()

    Map.put(tickets, :crypto.hash(:sha256, ticket), now + ttl)
  end

  defp add(tickets, _, _), do: tickets
end
