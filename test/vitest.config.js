import { defineConfig } from 'vitest/config'

export default defineConfig({
  test: {
    environment: 'node',
    // Acceptance steps are order-dependent (create -> verify -> update -> delete,
    // liveSync token progression); keep everything sequential.
    fileParallelism: false,
    sequence: { concurrent: false },
    // Serverless warehouse operations can be slow on cold start.
    testTimeout: 120_000,
    hookTimeout: 120_000,
  },
})
