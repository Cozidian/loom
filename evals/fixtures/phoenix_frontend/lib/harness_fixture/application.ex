defmodule HarnessFixture.Application do
  use Application
  def start(_type, _args) do
    Supervisor.start_link([HarnessFixture.Runtime], strategy: :one_for_one, name: HarnessFixture.Supervisor)
  end
end
