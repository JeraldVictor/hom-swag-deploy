# ── Stage 1: Build ────────────────────────────────────────────────────────────
# TanStack Start (Nitro SSR) — output lands in .output/
FROM node:22-alpine AS builder

WORKDIR /app

# Enable pnpm via corepack
RUN corepack enable && corepack prepare pnpm@latest --activate

# Install dependencies (cache layer)
COPY repos/app/package.json repos/app/pnpm-lock.yaml ./
RUN printf 'onlyBuiltDependencies:\n  - esbuild\n  - simple-git-hooks\n' > pnpm-workspace.yaml
RUN printf 'auto-install-peers=true\nonly-built-dependencies[]=esbuild\nonly-built-dependencies[]=simple-git-hooks\n' > .npmrc
RUN pnpm install --no-frozen-lockfile --ignore-scripts \
    && pnpm rebuild esbuild

# Build-time URLs (available to Vite/TanStack build)
ARG HS_API_URL=http://localhost:3000
ARG HS_LOGIN_URL=http://localhost:3000
ARG HS_MEDIA_URL=http://localhost:3000
ARG HS_BFF_URL=https://api.alpha.homswag.com/bff

# Copy source and build
COPY repos/app/ .
RUN printf 'VITE_API_BASE_URL=%s\nVITE_AUTH_API_BASE_URL=%s\nVITE_MEDIA_BASE_URL=%s\nVITE_BFF_BASE_URL=%s\nPUBLIC_API_BASE_URL=%s\nMEDIA_BASE_URL=%s\nBFF_BASE_URL=%s\n' \
        "$HS_API_URL" "$HS_LOGIN_URL" "$HS_MEDIA_URL" "$HS_BFF_URL" "$HS_API_URL" "$HS_MEDIA_URL" "$HS_BFF_URL" > .env.production \
    && pnpm build \
    && rm -f .env.production

# ── Stage 2: Runtime ──────────────────────────────────────────────────────────
FROM node:22-alpine AS runner

WORKDIR /app

# Nitro output is self-contained — copy only the .output directory
COPY --from=builder /app/.output ./.output

EXPOSE 3000

ARG HS_BFF_URL=https://api.alpha.homswag.com/bff

ENV PORT=3000 \
    NODE_ENV=production \
    BFF_BASE_URL=$HS_BFF_URL \
    VITE_BFF_BASE_URL=$HS_BFF_URL

CMD ["node", ".output/server/index.mjs"]
