defmodule BeamAgent.HTTPClient do
  @moduledoc "Replaceable stateless HTTP boundary used by network LLM providers."

  @callback post_json(String.t(), [{String.t(), String.t()}], map(), keyword()) ::
              {:ok, non_neg_integer(), map()} | {:error, term()}

  @callback get_json(String.t(), [{String.t(), String.t()}], keyword()) ::
              {:ok, non_neg_integer(), map()} | {:error, term()}
end
