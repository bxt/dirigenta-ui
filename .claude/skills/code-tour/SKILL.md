---
name: code-tour
description: Author a CodeTour walkthrough (.tours/*.tour) to explain a flow, feature, or the architecture of this codebase. Use when the user asks to "give me a tour", "walk me through how X works", "explain the architecture", "create a codetour", or otherwise wants a guided, step-by-step explanation they can click through in VS Code.
---

# Writing a CodeTour

[CodeTour](https://github.com/microsoft/codetour) is a VS Code extension that plays
back guided walkthroughs. A tour is a JSON file in `.tours/` — an ordered list of
steps, each anchored to a spot in a file with a markdown description. You author the
file; the user clicks through it in VS Code. You never run the extension, so your job
is to produce a well-formed tour whose anchors resolve — the validator below is how
you check that.

## Workflow

1. **Scope it.** Decide the flow/feature to explain and which files it touches.
   Trace real control/data flow — the tour should follow *how the code runs*, not
   the file tree.
2. **Read the anchor lines.** Open each file and copy the exact text you'll anchor
   to. Don't anchor from memory — patterns must match the current source.
3. **Write `.tours/<slug>.tour`.** Use the format in [reference.md](reference.md).
   One step per meaningful stop, ordered along the flow. Each `description` answers
   *what is this and why does it matter* in a few sentences.
4. **Validate.** Run:
   ```
   node .claude/skills/code-tour/scripts/validate-tour.mjs .tours/<slug>.tour
   ```
   It reports any anchor that matches nothing (unresolved) or matches more than once
   (ambiguous). Fix and re-run until it exits 0.
5. **Hand off.** Tell the user to open the tour from CodeTour's tour panel in VS
   Code (install the *CodeTour* extension if they don't have it). Tours aren't
   committed automatically — mention they can `git add .tours/<slug>.tour` if it's
   worth keeping.

## Rules for robust, useful tours

- **Anchor with `pattern` (a regex), not `line`.** Line numbers rot on the next
  edit; a pattern re-locates itself. Only fall back to `line` for a spot no stable
  text identifies.
- **Make each pattern unique in its file.** Include enough of the line that it can't
  match elsewhere — the validator rejects ambiguous patterns. Escape regex
  metacharacters (`(`, `)`, `.`, `[`, `$`, `\`, etc.).
- **Keep descriptions tight.** A few sentences of the *why*, not a paraphrase of the
  code the reader is already looking at. Link related steps and files (see
  reference.md) instead of repeating yourself.
- **Order by flow.** Launch → the thing that triggers next → … A newcomer should be
  able to follow the tour top-to-bottom and understand the path.
- **Pin with `ref` only for a snapshot.** For a tour of a specific commit/branch add
  a `ref`; leave it off for living docs that should track the default branch.

There's a worked example at [.tours/architecture-overview.tour](../../../.tours/architecture-overview.tour).
