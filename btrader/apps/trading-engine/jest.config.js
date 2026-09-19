/** @type {import('ts-jest').JestConfigWithTsJest} */
module.exports = {
  preset: 'ts-jest',
  testEnvironment: 'node',
  roots: ['<rootDir>/src'],
  testMatch: ['**/*.test.ts'],
  moduleNameMapper: {
    '^@btrader/engine-core$': '<rootDir>/../../packages/engine-core/src/index.ts',
    '^@btrader/shared$': '<rootDir>/../../packages/shared/src/index.ts',
    '^@btrader/db$': '<rootDir>/../../packages/db/src',
  },
  transform: {
    '^.+\\.tsx?$': ['ts-jest', { isolatedModules: true }],
  },
};
