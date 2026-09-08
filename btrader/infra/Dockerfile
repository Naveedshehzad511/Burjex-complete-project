# Multi-service build. Pass --build-arg SERVICE=<gateway-api|trading-engine|market-data|ws-gateway>
# Builds the pnpm monorepo, generates the Prisma client, and runs the chosen service.
FROM node:22-alpine AS base
# OpenSSL 3 — required so Prisma detects the right engine at generate time and
# can load it at runtime (Alpine ships libssl.so.3, not 1.1).
RUN apk add --no-cache openssl
RUN corepack enable && corepack prepare pnpm@9.15.4 --activate
WORKDIR /app

# ── deps ──
FROM base AS deps
COPY pnpm-workspace.yaml package.json pnpm-lock.yaml* tsconfig.base.json ./
COPY packages ./packages
COPY apps ./apps
RUN pnpm install --frozen-lockfile=false

# ── build ──
FROM deps AS build
ARG SERVICE
# Generate the Prisma client, then build the shared libraries to dist so the
# services consume their compiled output (not source) and tsc emits cleanly.
RUN pnpm --filter @btrader/db db:generate
RUN pnpm --filter @btrader/shared build
RUN pnpm --filter @btrader/db build
RUN pnpm --filter @btrader/engine-core build
RUN pnpm --filter @btrader/${SERVICE} build

# ── runtime ──
FROM base AS runtime
ARG SERVICE
ENV NODE_ENV=production
ENV SERVICE=${SERVICE}
COPY --from=build /app /app
WORKDIR /app/apps/${SERVICE}
# gateway-api builds to dist/main.js via nest; node services to dist/main.js via tsc
CMD ["node", "dist/main.js"]
