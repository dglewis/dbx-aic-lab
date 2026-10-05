# Agent guide — dbx-aic-lab

Context for AI coding agents (Claude Code, Cursor, etc.) working in this repo.

## What this is

A spike lab proving a bidirectional ICF connector between Databricks and
PingIDM/AIC. Before changing anything, read the documentation trail in the
order the README lists it. Current status: `docs/plan.md`. The repo keeps **both** paths runnable
on purpose; never retire the plain-JVM path in favour of Kubernetes.

## Hard rules

1. **Read the official, version-exact docs before setup/config work.** This
   project was repeatedly burned by pattern-matching from older releases and
   once by trusting a community thread over a live test. When a capability
   claim gates a decision and a cheap empirical test exists, run the test.
2. **Secrets never enter tracked files or command output.** Real credentials
   live only in `secrets/databricks.env` (gitignored; template:
   `secrets/databricks.env.example`) and the runtime's `boot.properties`.
   Tracked config carries `&{property}` placeholders only. Evidence loggers
   must redact hosts and never log Authorization headers.
3. **`runtime/` is disposable and untracked** — extracted vendor software
   plus live state. Never commit from it; `idm-config/deploy.sh` is the only
   way config reaches it. Tracked config in `idm-config/` is the source of
   truth; do not hand-edit the runtime copies except for throwaway probes.
4. **Ping vendor code stays out.** No copying from `runtime/openidm/samples/`
   (proprietary license headers) — scripts are written clean-room against the
   documented toolkit API. The same applies to the RCS distribution/image
   and ForgeOps — what is licensed how: `NOTICE.md`.
5. **Commits: only when the user says so.** Atomic (one logical change),
   plain imperative subject lines, no conventional-commit prefixes.
6. **Evidence discipline:** every acceptance/soak run writes a raw
   request/response log to `test/runs/` (gitignored, local only) with the
   commit in the header. Check claims of "it works" against a run log;
   record the result in `docs/spike-results.md`, not the log itself.

## Where things are documented

Each fact, rule, procedure, value or status lives in **one** place; every
other doc links to it. Before writing doc text, find its owner and edit
there. When something changes, update the owner and search the other docs
for stale copies in the same commit.

| Kind of content | Owner |
|---|---|
| Status and progress, open tasks | `docs/plan.md` |
| Current design and its rationale | `docs/design.md` |
| Procedures (runbooks), versions, prerequisites | `README.md` |
| Open questions, research evidence, vendor citations | `docs/rcs-kubernetes-research.md` (Unknowns table, Sources) |
| What a Databricks team must provide | `docs/databricks-requirements.md` — a standalone handout; others link to it |
| Licensing and redistribution | `NOTICE.md` |
| Rules for agents | this file — pointers, not copies |

Dated records keep their wording: `docs/spike-results.md` (what happened on
a date) and the ADRs (what was decided and why). Don't restate them
elsewhere as current guidance.

Enforcement: `node scripts/check-docs.mjs` (links, anchors, and the owned
facts in `scripts/doc-owners.json`), run by the git pre-commit hook in
`.githooks/`. The procedure for agents is the skill in
`.agents/skills/docs-single-source/` (`.claude/skills` links to it).

## Conventions

- Naming (provisioners per system, object classes per dataset), the sync
  token and the timestamp format: `docs/design.md`.
- Groovy SQL: build statements as plain String concatenation with `?`
  parameters — GString interpolation becomes prepared-statement params,
  which breaks identifiers. `table_changes()` args cannot be parameters.
- Connector auth (customizer, and why it is a plain script body):
  `docs/design.md` → Credential path.
- Known gotchas: quoting values with `;` —
  `secrets/databricks.env.example`; cold-start and fresh-pod failures —
  `docs/design.md` → Setting up OAuth M2M, step 6; research Unknowns #14.

## Verify your changes

```bash
# Lab up? (DS on 31389, IDM on 8443 — see README runbook)
curl -k -u openidm-admin:openidm-admin https://localhost:8443/openidm/info/ping
idm-config/deploy.sh <topology>       # local | rcs-client | rcs-k8s | rcs — see the README runbook
cd test && npm test                   # 16 checks; writes test/runs/ + JUnit XML
npm run test:unit                     # offline unit tests (auth selection); run from test/
```

`idm-config/acceptance-test.sh` is the zero-dependency smoke fallback;
`databricks/smoke-test.sh` isolates driver/network/auth below the connector.
