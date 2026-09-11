defmodule BeamAgent.Missions.Report do
  @moduledoc "Deterministic presentation of advisory text. Parsed labels are not verification claims."
  def id(report),
    do: hash(Enum.map_join(["worker_id", "fingerprint", "content"], "\n", &(report[&1] || "")))

  def present(report) do
    text = report["content"] || ""
    chunks = Regex.split(~r/^\s*\d+[.)]\s+/m, text, trim: false)

    {intro, findings} =
      case chunks do
        [only] ->
          no_findings =
            String.trim(only) == "" or
              Regex.match?(~r/\A(?:REVIEW_PASS|No actionable)/i, String.trim(only))

          {"", if(no_findings, do: [], else: [finding("Assessment", only)])}

        [intro | rest] ->
          {String.trim(intro),
           Enum.map(rest, fn chunk ->
             [title | body] = String.split(chunk, "\n")
             finding(clean(title), Enum.join(body, "\n"))
           end)}
      end

    Map.merge(report, %{
      "id" => id(report),
      "intro" => intro,
      "findings" => Enum.take(findings, 3)
    })
  end

  def select(report, report_id, finding_id) when is_map(report) do
    shown = present(report)

    if shown["id"] == report_id and report["status"] == "advisory" do
      case Enum.find(shown["findings"], &(&1["id"] == finding_id)) do
        nil -> {:error, :finding_unavailable}
        finding -> {:ok, finding}
      end
    else
      {:error, :report_replaced_or_stale}
    end
  end

  def select(_, _, _), do: {:error, :report_unavailable}

  defp finding(title, body) do
    sections =
      Regex.scan(
        ~r/^\s*[-*]?\s*\*{0,2}(Evidence|Uncertainty|Next action):\*{0,2}\s*(.*)$/mi,
        body
      )
      |> Map.new(fn [_, label, value] -> {String.downcase(label), clean(value)} end)

    %{
      "id" => hash(title <> "\n" <> body),
      "title" => title,
      "body" => String.trim(body),
      "sections" => sections
    }
  end

  def clean(text), do: text |> String.replace("**", "") |> String.trim()
  defp hash(text), do: :crypto.hash(:sha256, text) |> Base.encode16(case: :lower)
end
