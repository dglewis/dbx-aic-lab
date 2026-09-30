#!/usr/bin/env node
// Documentation drift check (no dependencies; Node 18+). Run from anywhere:
//   node scripts/check-docs.mjs
// Also runs as the git pre-commit hook (.githooks/pre-commit).
//
// 1. Links: every relative Markdown link in tracked *.md files points to an
//    existing file, and every #anchor to an existing heading.
// 2. Owned facts: each entry in scripts/doc-owners.json is a pattern for a
//    fact that must be stated only in its owner file (AGENTS.md → "Where
//    things are documented"). A match anywhere else fails, except in dated
//    records (spike-results, ADRs), which keep their wording.
import { readFileSync, existsSync, statSync } from 'node:fs'
import { execFileSync } from 'node:child_process'
import { dirname, join, relative, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const DATED_RECORDS = [/^docs\/spike-results\.md$/, /^docs\/adr-[^/]+\.md$/]

const mdFiles = execFileSync('git', ['ls-files', '*.md'], { cwd: root, encoding: 'utf8' })
  .split('\n').filter(Boolean)
const text = Object.fromEntries(mdFiles.map((f) => [f, readFileSync(join(root, f), 'utf8')]))

// GitHub's heading slug: lowercase, drop punctuation except '-' and spaces,
// spaces to '-'. Duplicate headings get -1, -2 … suffixes.
function anchors(md) {
  const seen = new Map()
  const out = new Set()
  for (const line of md.replace(/```[\s\S]*?```/g, '').split('\n')) {
    const m = /^#{1,6}\s+(.*?)\s*#*\s*$/.exec(line)
    if (!m) continue
    const base = m[1].toLowerCase().replace(/[^\p{L}\p{N} _-]/gu, '').replace(/ /g, '-')
    const n = seen.get(base) ?? 0
    seen.set(base, n + 1)
    out.add(n ? `${base}-${n}` : base)
  }
  return out
}

const problems = []

// 1. Links (ignoring code blocks and inline code)
for (const [file, md] of Object.entries(text)) {
  const body = md.replace(/```[\s\S]*?```/g, '').replace(/`[^`\n]*`/g, '')
  for (const [, target] of body.matchAll(/\]\(([^)\s]+)\)/g)) {
    if (/^[a-z]+:/i.test(target)) continue // http:, https:, mailto:
    const [path, anchor] = target.split('#')
    const dest = path ? resolve(root, dirname(file), decodeURI(path)) : join(root, file)
    if (!existsSync(dest)) { problems.push(`${file}: broken link → ${target}`); continue }
    if (anchor && statSync(dest).isFile() && dest.endsWith('.md')) {
      if (!anchors(readFileSync(dest, 'utf8')).has(anchor)) {
        problems.push(`${file}: missing anchor → ${target}`)
      }
    }
  }
}

// 2. Owned facts
const owners = JSON.parse(readFileSync(join(root, 'scripts', 'doc-owners.json'), 'utf8'))
for (const { fact, pattern, owner } of owners.facts) {
  const re = new RegExp(pattern)
  if (!text[owner]) { problems.push(`doc-owners.json: owner ${owner} of "${fact}" is not a tracked .md file`); continue }
  if (!re.test(text[owner])) problems.push(`doc-owners.json: "${fact}" not found in its owner ${owner}`)
  for (const [file, md] of Object.entries(text)) {
    if (file === owner || DATED_RECORDS.some((d) => d.test(file))) continue
    md.split('\n').forEach((line, i) => {
      if (re.test(line)) problems.push(`${file}:${i + 1}: restates "${fact}" — owner is ${owner}; link to it instead`)
    })
  }
}

if (problems.length) {
  console.error(`docs check: ${problems.length} problem(s)\n` + problems.map((p) => `  ${p}`).join('\n'))
  process.exit(1)
}
console.log(`docs check: ok (${mdFiles.length} files, ${owners.facts.length} owned facts)`)
