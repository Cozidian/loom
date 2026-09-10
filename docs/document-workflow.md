# Word templates, through the runtime

This is a bounded, insert-only workflow for paragraph-based `.docx` templates,
not a general Word editor. The model researches the workspace and fills a new
copy; the runtime checks preservation and independently reviews the result.

## Run

Build once with `mix beam_agent.build`. Configure your provider through the normal
first launch (`./beam_agent`) if needed. Then:

```sh
./beam_agent document doctor
./beam_agent document test.docx --output test-ros-new.docx \
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
then produces a PDF, page PNGs and machine evidence in a fresh sibling review
directory. **Inspect every page before accepting the result.** Rendering alone
is not visual or factual review; machine evidence deliberately leaves
`visually_reviewed` false.

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
./beam_agent document render test-ros-new.docx review-ros-new
```

The review directory must not already exist and its parent must exist. Failed
attempts can leave partial review artifacts for inspection. The render-only
command checks that its input stays unchanged; it does not rerun the original
template comparison or model review.

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

`read_document`, `fill_document` and `render_document` are also registered runtime
tools. Outside this dedicated command, normal session capabilities and approval
policy apply; desktop rendering additionally requires the explicit
`desktop-document` browser scope. Native Word automation is a distinct desktop
capability, not a claim of OS-sandboxed document parsing.

## ROS trial — 2026-09-10

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
