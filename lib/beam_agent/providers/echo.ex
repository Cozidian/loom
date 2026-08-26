defmodule BeamAgent.Providers.Echo do
  @moduledoc "A deterministic provider used for recovery and embedding examples."
  @behaviour BeamAgent.LLMProvider

  @impl true
  def id, do: :echo

  @impl true
  def complete(messages, _tools, _options) do
    user_messages = Enum.filter(messages, &(&1.role == :user))
    last = List.last(user_messages)

    {:ok,
     %{
       content: "echo(#{length(user_messages)}): #{last && last.content}",
       tool_calls: []
     }}
  end
end
