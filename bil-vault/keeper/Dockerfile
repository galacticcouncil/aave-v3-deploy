# syntax=docker/dockerfile:1.6

# ── Build stage: compile TS → JS ───────────────────────────────────────────────
FROM node:22-alpine AS builder

WORKDIR /app

COPY package.json package-lock.json tsconfig.json ./
RUN npm ci --no-audit --no-fund

COPY src ./src
RUN npm run build

# ── Runtime stage: minimal image, production deps only ────────────────────────
FROM node:22-alpine AS runtime

WORKDIR /app

ENV NODE_ENV=production \
    NPM_CONFIG_LOGLEVEL=warn

COPY package.json package-lock.json ./
RUN npm ci --omit=dev --no-audit --no-fund && npm cache clean --force

COPY --from=builder /app/dist ./dist

# Drop root. The `node` user is provided by the base image (uid 1000).
USER node

# No exposed port — the keeper is an outbound-only polling client.
# Healthcheck strategy: docker swarm restart_policy + per-cycle stdout logging.
# A real liveness check would need an embedded HTTP server (out of scope).

CMD ["node", "dist/index.js"]
