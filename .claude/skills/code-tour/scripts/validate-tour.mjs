#!/usr/bin/env node
// Validate a CodeTour `.tour` file against the current working tree.
//
// CodeTour (the VS Code extension) resolves each step's `pattern` with a
// JavaScript `RegExp`, so this validator uses the same engine — if it passes
// here, the anchors resolve in the extension too. Stdlib only; no deps.
//
// Usage:  node validate-tour.mjs <path-to.tour> [more.tour ...]
// Exit 0 when every step in every tour resolves to exactly one anchor;
// non-zero otherwise, with a per-step report.

import { readFileSync, existsSync, statSync } from "node:fs";
import { resolve, join, isAbsolute } from "node:path";
import { execSync } from "node:child_process";

/** Repo root, so `file` fields resolve regardless of the caller's cwd. */
function repoRoot() {
  try {
    return execSync("git rev-parse --show-toplevel", {
      encoding: "utf8",
    }).trim();
  } catch {
    return process.cwd();
  }
}

const ROOT = repoRoot();

/** Validate one tour file. Returns the number of problems found. */
function validateTour(tourPath) {
  const rel = tourPath;
  let problems = 0;
  const fail = (msg) => {
    console.error(`  ✗ ${msg}`);
    problems++;
  };

  let raw;
  try {
    raw = readFileSync(tourPath, "utf8");
  } catch (e) {
    console.error(`✗ ${rel}: cannot read — ${e.message}`);
    return 1;
  }

  let tour;
  try {
    tour = JSON.parse(raw);
  } catch (e) {
    console.error(`✗ ${rel}: invalid JSON — ${e.message}`);
    return 1;
  }

  console.log(`\n${rel}`);
  if (typeof tour.title !== "string" || !tour.title.trim()) {
    fail('missing or empty "title"');
  }
  if (!Array.isArray(tour.steps) || tour.steps.length === 0) {
    fail('missing or empty "steps" array');
    return problems; // nothing more to check
  }

  tour.steps.forEach((step, i) => {
    const n = i + 1;

    // A step anchors to a file (via line/pattern) OR a directory/uri.
    if (step.directory || step.uri) {
      if (step.directory) {
        const p = join(ROOT, step.directory);
        if (!existsSync(p) || !statSync(p).isDirectory()) {
          fail(`step ${n}: directory not found — ${step.directory}`);
        }
      }
      return; // uri steps and existing directories are fine
    }

    if (typeof step.file !== "string") {
      fail(`step ${n}: no "file", "directory", or "uri"`);
      return;
    }

    const filePath = isAbsolute(step.file)
      ? step.file
      : join(ROOT, step.file);
    if (!existsSync(filePath)) {
      fail(`step ${n}: file not found — ${step.file}`);
      return;
    }

    const hasPattern = typeof step.pattern === "string";
    const hasLine = Number.isInteger(step.line);
    if (!hasPattern && !hasLine) {
      fail(`step ${n} (${step.file}): needs a "pattern" or "line"`);
      return;
    }

    const content = readFileSync(filePath, "utf8");

    if (hasPattern) {
      let re;
      try {
        re = new RegExp(step.pattern, "gm");
      } catch (e) {
        fail(`step ${n} (${step.file}): invalid regex — ${e.message}`);
        return;
      }
      const count = (content.match(re) || []).length;
      if (count === 0) {
        fail(
          `step ${n} (${step.file}): pattern matches nothing — /${step.pattern}/`
        );
      } else if (count > 1) {
        fail(
          `step ${n} (${step.file}): pattern is ambiguous (${count} matches) — /${step.pattern}/`
        );
      } else {
        console.log(`  ✓ step ${n}: ${step.file}`);
      }
    } else {
      const lineCount = content.split("\n").length;
      if (step.line < 1 || step.line > lineCount) {
        fail(
          `step ${n} (${step.file}): line ${step.line} out of range (1–${lineCount})`
        );
      } else {
        console.log(`  ✓ step ${n}: ${step.file}:${step.line}`);
      }
    }
  });

  return problems;
}

const args = process.argv.slice(2);
if (args.length === 0) {
  console.error("usage: node validate-tour.mjs <path-to.tour> [more.tour ...]");
  process.exit(2);
}

let total = 0;
for (const arg of args) {
  total += validateTour(resolve(arg));
}

if (total > 0) {
  console.error(`\n${total} problem(s) found.`);
  process.exit(1);
}
console.log("\nAll anchors resolve. ✓");
