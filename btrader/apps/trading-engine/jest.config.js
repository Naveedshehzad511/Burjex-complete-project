/** @type {import('ts-jest').JestConfigWithTsJest} */
module.exports = {
  preset: 'ts-jest',
  testEnvironment: 'node',
  roots: ['<rootDir>/src'],
  testMatch: ['**/*.test.ts'],
  moduleNameMapper: {
    '^@btrader/engine-core$': '<rootDir>/../../packages/engine-core/src',
    '^@btrader/shared$': '<rootDir>/../../packages/shared/src',
    '^@btrader/db$': '<rootDir>/../../packages/db/src',
  },
};
