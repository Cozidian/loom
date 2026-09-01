defmodule ClipboardFixture.Editor do
  @moduledoc "A deliberately incomplete editor boundary used by the coding eval suite."

  def new(document \\ ""), do: %{document: document, attachments: []}

  def paste(_state, _clipboard_item), do: {:error, :not_implemented}
end
