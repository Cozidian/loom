# Clipboard image paste fixture

Implement `ClipboardFixture.Editor.paste/2` as the boundary between a UI
clipboard event and the editor state.

The function must:

- accept non-empty `image/png` and `image/jpeg` payloads;
- append an attachment containing a stable id, MIME type, filename, byte size,
  and the original binary data;
- append Markdown image syntax using `attachment://ID` to the document;
- preserve existing document content and attachments;
- use `pasted-image.png` or `pasted-image.jpg` when the filename is absent;
- return `{:error, :unsupported_clipboard_item}` for other MIME types and
  `{:error, :empty_image}` for empty image data.

`paste/2` returns `{:ok, updated_state}` on success. Keep the implementation
dependency-free and do not change the tests.
