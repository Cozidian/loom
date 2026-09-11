# Word templates, through the runtime

This is a bounded, insert-only workflow for paragraph-based `.docx` templates,
not a general Word editor. The model researches the workspace and fills a new
copy; the runtime checks preservation and independently reviews the result.

## Run

Build once with `mix loom.build`. Configure your provider through the normal
first launch (`./loom`) if needed. Supply your own non-sensitive paragraph-based
template; personal trial documents are intentionally not distributed. For example:

```sh
./loom document doctor
./loom document template.docx --output assessment.docx \
  --prompt "Fill in the ROS analysis in Norwegian using this repository. Separate current controls, remaining risks and proposed measures; cite source files."
```

Choose a **new output filename** on each run. `--workspace PATH` chooses the
repository/document folder; `--profile NAME` selects an existing provider profile
without changing settings. The command uses the selected provider account and
can consume its allowance. Missing usage counters mean unknown, not free work.

The owner uses a solo work strategy with an independent runtime reviewer. Only
workspace-reading tools and `fill_document` are available to the model, with
automatic approval for that bounded set. Runtime restrictions bind filling to
the exact source and output pair and propagate to children. General writes,
shell execution, publication and arbitrary output paths are not enabled by this
command. The trusted CLI supplies the deterministic verification command.

After successful runtime work, the CLI renders a private copy in Microsoft Word,
then produces a PDF, page PNGs and fingerprint evidence in a fresh sibling review
directory. A separate, read-only reviewer receives every page image and returns
a per-page layout assessment. It has no tools and cannot rerun repository tests
or research. The command succeeds only when every page is assessed as passed.

This is **model-assessed layout, not factual or organizational approval**. It is
fallible; inspect the pages before consequential use. The immutable render receipt
still says `visually_reviewed: false`: rendering alone proves no visual review.
A separate `visual-review-*.json` records the model assessment, source/page hashes
and reviewer session. It does not retroactively change the render receipt.

## Dependencies and recovery

Editing/inspection use OTP ZIP/XML facilities. The current rendering adapter
requires macOS, Microsoft Word in `/Applications`, Poppler's `pdfinfo` and
`pdftoppm`, and permission to automate Word. `document doctor` checks installed
components; an actual render is needed to verify desktop automation permission.
Nothing is installed or granted automatically. Word may briefly come forward.
Only a uniquely named private copy is opened/exported/closed; the source and
other open documents are not saved or closed.

If rendering fails after the model has produced a valid output, recover without
another model call:

```sh
./loom document render assessment.docx assessment-review
```

The review directory must not already exist and its parent must exist. Failed
attempts can leave partial review artifacts for inspection. The render-only
command checks that its input stays unchanged; it does not rerun the original
template comparison or model review.

If visual assessment fails, retry it against the existing render without
regenerating the document or repeating the repository research:

```sh
./loom document review assessment.docx assessment-review
```

`--profile NAME` can select an existing image-capable profile. The assessment
uses provider allowance. This first implementation supports 1–10 PNG pages,
10 MiB per image and 20 MiB total image data. Missing vision support, incomplete
page assessments, concerns or uncertainty return a nonzero exit status and leave
the output available. Missing/stale fingerprints are rejected before inference;
source, PDF and page hashes are rechecked afterward. Old render receipts without
page/PDF hashes require a fresh render. Each assessment gets a new report file.

## What is checked

- Read-before-write and source fingerprint consistency; exclusive output creation.
- Original archive unchanged; unrelated output ZIP entries byte-identical.
- Original paragraph text retained in order, with a real addition to the output.
- ZIP/XML integrity, bounded expansion and paragraph sizes; unsafe paths,
  external relationships, DTD/entities and embedded active content are rejected.
- Fill anchors match exact numbered paragraph text. Tables, text boxes and
  tracked changes are rejected by this first filling implementation.
- Word rendering rejects dynamic fields; PDF page count and all page images
  must be present. These checks do not establish factual correctness.
- Visual assessment is isolated from general implementation/verification goals;
  it cannot run workspace-discovered commands. Offline regressions cover image
  delivery, stale/substituted evidence, all-page coverage and uncertainty.

`read_document`, `fill_document` and `render_document` are also registered runtime
tools. Outside this dedicated command, normal session capabilities and approval
policy apply; desktop rendering additionally requires the explicit
`desktop-document` browser scope. Native Word automation is a distinct desktop
capability, not a claim of OS-sandboxed document parsing.

## ROS trial — 2026-09-10

These are historical observations from a private local trial, not downloadable
fixtures or reproducible public benchmarks. Offline tests generate synthetic
documents independently of those files.

The owner supplied `test.docx`, a 14-paragraph ROS template. The live harness used
the existing `openai-chatgpt / gpt-5.6-sol` profile to produce
`test-ros-agent.docx`, filling current-state and residual-risk/measure fields for
risks 164, 167, 172 and 174 using repository evidence.

- Session: `session-dHoyU7_7ttV2psi7` in the owner's local durable store.
- Deterministic integrity verification and independent runtime review passed.
- Original SHA-256: `2f31a2cd623a5fa46fa4a563dfd0099dcea30aab0405854c9660ade224cf94af`.
- Output SHA-256: `d2cf5972789425438525574a5679611238237ff5dacf7def74affe575b909b5c`.
- The final file opened/rendered through native Word. Both pages were visually
  inspected by the supervising coding assistant, with no clipping or missing
  glyphs observed. This was not autonomous visual review inside BeamAgent.
- The root trace records 25 tool calls. Provider token counters were absent;
  total usage is unknown. This count excludes the separate reviewer's activity.

The trial needed intervention: an initial model-capability mismatch, then a
reviewer path-inheritance defect, followed by a native Word export failure.
The first two were fixed before the successful runtime rerun. That process had
already loaded the old renderer, so its export was recovered with the corrected
render-only command, without another model turn. Regression tests cover document
integrity, exact output binding, reviewer scope and canonical usage events.
This is evidence of a real guarded delivery with supervised recovery, not a
reliability benchmark or proof that arbitrary Word documents are supported.

## Image-assessment trial — 2026-09-10

The later `test-ros-trial-20260910.docx` output was rendered again unchanged and
both pages were assessed through the new `document review` command. Reviewer
`session-eu0UwFUZCfItQ5VH` reported both pages passed using one runtime model
invocation, zero tools and zero repository verification commands. Tokens were
not reported. The output fingerprint remained
`c15afeea0f5cd5fc42a3aeb2f83be560e2c8fdfec7c9f5a1f24f3ed0c4f5ca26`.

The first development attempt accidentally invoked general repository verification
because its root goal was classified as a verification task. It failed, rather than
claiming completion. The corrected path uses a dedicated supervised reviewer and
has an offline regression ensuring workspace verification commands never run.
This validates retrying QA without repeating generation; a fresh full document
generation with automatic QA still needs another end-to-end trial.
