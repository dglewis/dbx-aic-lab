---
name: docs-single-source
description: Use before writing or changing any Markdown documentation in this repo (README.md, AGENTS.md, NOTICE.md, docs/*.md), including recording test results, decisions, findings or procedures. Keeps every fact in one owner doc so the docs don't drift.
---

# Docs: one owner per fact

Every fact, rule, procedure, value and status lives in **one** doc; every
other doc links to it. The owner for each kind of content is the table in
`AGENTS.md` → "Where things are documented". Dated records
(`docs/spike-results.md`, `docs/adr-*.md`) keep their wording and are never
restated elsewhere as current guidance.

## Before writing

1. Classify the content (status, design/rationale, procedure/version, open
   question/citation, Databricks-team ask, licensing, agent rule) and find
   its owner in the `AGENTS.md` table.
2. Search all docs for where the fact is already stated — by its key terms
   and values, not only by heading:
   `git grep -n -i "<term>" -- '*.md'`
3. If it already lives in its owner, edit it there. If it lives somewhere
   else, move it to the owner and leave a link behind.

## While writing

- State it once, in the owner. Elsewhere, link to the owner's section
  (`[design.md → Topology](docs/design.md#topology)`) instead of restating
  it — even as a one-line summary of values or steps.
- New results go in `docs/spike-results.md` as a dated entry; the owner doc
  states the resulting current truth.

## After any change

1. Search for stale copies of what changed (old names, values, statuses)
   and fix them in the same commit.
2. If you consolidated a duplicate, add its pattern to
   `scripts/doc-owners.json` so the check catches it next time.
3. Run `node scripts/check-docs.mjs` — it must pass. The git pre-commit hook
   (`.githooks/`) runs it too.
