defmodule BeamAgent.Stream.SSEDecoder do
  @moduledoc false

  def new, do: ""

  def feed(buffer, chunk) when is_binary(buffer) and is_binary(chunk) do
    split_frames(buffer <> chunk, [])
  end

  def finish(buffer) do
    if String.trim(buffer) == "" do
      {[], ""}
    else
      {[decode_frame(buffer)], ""}
    end
  end

  defp split_frames(buffer, acc) do
    case separator(buffer) do
      nil ->
        {Enum.reverse(acc), buffer}

      {index, length} ->
        frame = binary_part(buffer, 0, index)
        rest = binary_part(buffer, index + length, byte_size(buffer) - index - length)
        split_frames(rest, [decode_frame(frame) | acc])
    end
  end

  defp separator(buffer) do
    [
      case :binary.match(buffer, "\n\n") do
        :nomatch -> nil
        {index, _length} -> {index, 2}
      end,
      case :binary.match(buffer, "\r\n\r\n") do
        :nomatch -> nil
        {index, _length} -> {index, 4}
      end
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.min_by(&elem(&1, 0), fn -> nil end)
  end

  defp decode_frame(frame) do
    Enum.reduce(String.split(frame, ~r/\r?\n/), %{event: nil, data: []}, fn line, acc ->
      cond do
        String.starts_with?(line, "event:") ->
          %{acc | event: line |> String.trim_leading("event:") |> String.trim_leading()}

        String.starts_with?(line, "data:") ->
          data = line |> String.trim_leading("data:") |> String.trim_leading()
          %{acc | data: acc.data ++ [data]}

        true ->
          acc
      end
    end)
    |> Map.update!(:data, &Enum.join(&1, "\n"))
  end
end
