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
ARG HS_API_URL=https://api.alpha.homswag.com
ARG HS_LOGIN_URL=https://api.alpha.homswag.com
ARG HS_MEDIA_URL=https://api.alpha.homswag.com
ARG HS_BFF_URL=https://api.alpha.homswag.com/bff
ARG HS_SERVER_BFF_URL=https://api.alpha.homswag.com/bff
ARG HS_ENABLE_RUM=false
ARG HS_RUM_TRACES_ENDPOINT=
ARG HS_RUM_SERVICE_NAME=customer-app
ARG HS_DEPLOYMENT_ENVIRONMENT=production

# Copy source and build
COPY repos/app/ .
RUN printf 'VITE_API_BASE_URL=%s\nVITE_AUTH_API_BASE_URL=%s\nVITE_MEDIA_BASE_URL=%s\nVITE_BFF_BASE_URL=%s\nVITE_ENABLE_RUM=%s\nVITE_RUM_TRACES_ENDPOINT=%s\nVITE_RUM_SERVICE_NAME=%s\nVITE_DEPLOYMENT_ENVIRONMENT=%s\nPUBLIC_API_BASE_URL=%s\nMEDIA_BASE_URL=%s\nBFF_BASE_URL=%s\n' \
        "$HS_API_URL" "$HS_LOGIN_URL" "$HS_MEDIA_URL" "$HS_BFF_URL" "$HS_ENABLE_RUM" "$HS_RUM_TRACES_ENDPOINT" "$HS_RUM_SERVICE_NAME" "$HS_DEPLOYMENT_ENVIRONMENT" "$HS_API_URL" "$HS_MEDIA_URL" "$HS_SERVER_BFF_URL" > .env.production \
    && cp .env.production .env.prod \
    && pnpm build \
    && node -e 'const fs=require("fs"),path=require("path"); const [from,to]=process.argv.slice(1); const walk=(dir)=>{for(const ent of fs.readdirSync(dir,{withFileTypes:true})){const p=path.join(dir,ent.name); if(ent.isDirectory()) walk(p); else if(/\.(mjs|js|json)$/.test(ent.name)){const s=fs.readFileSync(p,"utf8"); const n=s.split(from).join(to); if(n!==s) fs.writeFileSync(p,n);}}}; if(from&&to&&from!==to) walk(".output/server");' "$HS_BFF_URL" "$HS_SERVER_BFF_URL" \
    && rm -f .env.production .env.prod

# ── Stage 2: Runtime ──────────────────────────────────────────────────────────
FROM node:22-alpine AS runner

WORKDIR /app

# Nitro output is self-contained — copy only the .output directory
COPY --from=builder /app/.output ./.output

EXPOSE 3000

ARG HS_BFF_URL=https://api.alpha.homswag.com/bff
ARG HS_SERVER_BFF_URL=https://api.alpha.homswag.com/bff

ENV PORT=3000 \
    NODE_ENV=production \
    BFF_BASE_URL=$HS_SERVER_BFF_URL \
    VITE_BFF_BASE_URL=$HS_BFF_URL

CMD ["node", ".output/server/index.mjs"]
