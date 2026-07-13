# CodeTour `.tour` format reference

A tour is a JSON file in `.tours/` (repo root). The `title` is what VS Code shows in
the tour list; the filename is free. Schema URL: `https://aka.ms/codetour-schema`.

## Top-level fields

| Field         | Req | Meaning |
|---------------|-----|---------|
| `$schema`     | no  | `https://aka.ms/codetour-schema` — enables editor validation. |
| `title`       | yes | Name shown in the CodeTour panel. |
| `description` | no  | Subtitle / summary of the tour. |
| `steps`       | yes | Ordered array of step objects (below). |
| `ref`         | no  | Git branch, tag, or commit to pin anchors to. Omit for a tour that should track the current branch. |
| `isPrimary`   | no  | `true` marks the tour CodeTour offers first (e.g. an onboarding tour). |
| `when`        | no  | A JS expression gating when the tour is listed (advanced; rarely needed). |
| `nextTour`    | no  | Title of a tour to chain to at the end. |

## Step fields

Each step needs a **location** and a **description**.

Location — one of:

| Field       | Meaning |
|-------------|---------|
| `file`      | Repo-relative path. Combine with `pattern` (preferred) or `line`. |
| `directory` | Repo-relative directory — a step about a folder rather than a line. |
| `uri`       | Absolute URI for a file outside the workspace. |

Within a `file`:

| Field       | Meaning |
|-------------|---------|
| `pattern`   | **Preferred.** A regex; CodeTour anchors to the first match. Robust against edits above it. Must be unique (the validator enforces this). |
| `line`      | 1-based line number. Brittle — avoid unless no stable text identifies the spot. |
| `selection` | Optional `{ start: {line, character}, end: {line, character} }` to highlight a range. |

Other:

| Field         | Meaning |
|---------------|---------|
| `description` | Markdown shown for the step. Required. |
| `title`       | Optional short label for the step (otherwise CodeTour numbers it). |

## Markdown affordances in `description`

- **Link to another step:** `[see step 3](#3)` — jumps within the tour.
- **Link to a file/line:** standard markdown link to a workspace-relative path.
- **Shortcut to a tour:** `[Start here](command:codetour.startTourByTitle?["Architecture Overview"])`.
- **Insert-code / run-command buttons** and shell blocks (`>> command`) exist for
  interactive tutorials — rarely needed for explanatory tours.

## Minimal example

```json
{
  "$schema": "https://aka.ms/codetour-schema",
  "title": "Login flow",
  "steps": [
    {
      "file": "src/Auth.swift",
      "pattern": "func signIn\\(",
      "description": "Entry point for sign-in. Validates the form, then calls the token exchange in the next step."
    }
  ]
}
```

## Validating

```
node ${CLAUDE_SKILL_DIR}/scripts/validate-tour.mjs .tours/<slug>.tour
```

(`${CLAUDE_SKILL_DIR}` is this skill's own directory — it resolves regardless of
where the skill is installed or which directory you run from.)

Uses Node's `RegExp` (the same engine CodeTour uses) so a pass here predicts a clean
playback. Flags patterns that match nothing or match more than once, missing files,
and out-of-range lines; exits non-zero if anything fails.
