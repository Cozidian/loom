defmodule BeamAgent.HTTPClient do
  @moduledoc "Replaceable stateless HTTP boundary used by network LLM providers."

  @callback post_json(String.t(), [{String.t(), String.t()}], map(), keyword()) ::
              {:ok, non_neg_integer(), map()} | {:error, term()}

  @callback post_json_stream(
              String.t(),
              [{String.t(), String.t()}],
              map(),
              keyword(),
              state,
              (binary(), state -> {:ok, state} | {:error, term()})
            ) ::
              {:ok, non_neg_integer(), :streamed, state}
              | {:ok, non_neg_integer(), map()}
              | {:error, term()}
            when state: term()

  @callback get_json(String.t(), [{String.t(), String.t()}], keyword()) ::
              {:ok, non_neg_integer(), map()} | {:error, term()}

  @optional_callbacks post_json_stream: 6
end
