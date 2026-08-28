defmodule BeamAgent.Auth.Keyring.Memory do
  @moduledoc false
  @behaviour BeamAgent.Auth.Keyring

  @impl true
  def init(_opts), do: {:ok, %{}}

  @impl true
  def put(reference, secret, entries), do: {:ok, Map.put(entries, reference, secret)}

  @impl true
  def fetch(reference, entries) do
    case Map.fetch(entries, reference) do
      {:ok, secret} -> {{:ok, secret}, entries}
      :error -> {{:error, :credential_not_found}, entries}
    end
  end

  @impl true
  def delete(reference, entries), do: {:ok, Map.delete(entries, reference)}
end
