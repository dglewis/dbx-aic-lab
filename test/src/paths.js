// Repo paths, importable without loading the profile (which reads secrets).
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

export const testRoot = join(dirname(fileURLToPath(import.meta.url)), '..')
export const repoRoot = join(testRoot, '..')
