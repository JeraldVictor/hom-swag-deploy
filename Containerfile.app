# ── Stage 1: Build ────────────────────────────────────────────────────────────
# TanStack Start (Nitro SSR) — output lands in .output/
FROM node:22-alpine AS builder

WORKDIR /app

# Enable pnpm via corepack
RUN corepack enable && corepack prepare pnpm@latest --activate

# Install dependencies (cache layer)
COPY repos/app/package.json repos/app/pnpm-lock.yaml ./
RUN pnpm install --no-frozen-lockfile

# Copy source and build
COPY repos/app/ .
RUN pnpm build

# ── Stage 2: Runtime ──────────────────────────────────────────────────────────
FROM node:22-alpine AS runner

WORKDIR /app

# Nitro output is self-contained — copy only the .output directory
COPY --from=builder /app/.output ./.output

EXPOSE 3000

ENV PORT=3000 \
    NODE_ENV=production

CMD ["node", ".output/server/index.mjs"]
