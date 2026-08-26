defmodule BeamAgent.Stream.NDJSONDecoder do
  @moduledoc false

  def new, do: ""

  def feed(buffer, chunk) when is_binary(buffer) and is_binary(chunk) do
    parts = String.split(buffer <> chunk, "\n")
    {complete, [rest]} = Enum.split(parts, -1)
    {Enum.reject(Enum.map(complete, &String.trim_trailing(&1, "\r")), &(&1 == "")), rest}
  end

  def finish(buffer) do
    case String.trim(buffer) do
      "" -> {[], ""}
      line -> {[line], ""}
    end
  end
end
