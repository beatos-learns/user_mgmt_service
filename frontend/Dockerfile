# syntax=docker/dockerfile:1
# frontend/Dockerfile | containerize the Next.js auth portal (https://github.com/yagan93/auth_portal).
#
# The source is pulled straight from GitHub via BuildKit's git ADD, so this repo
# stays the single deployment entry point (no local clone needed):
#   docker compose build frontend
#
# NEXT_PUBLIC_API_URL is inlined into the client bundle at build time — rebuild
# the image to point the portal at a different backend URL.

ARG NODE_VERSION=22

# ---- Build stage: install with pnpm and compile the production bundle -------
# Debian-based (not alpine) so any prebuilt native modules pnpm pulls in are
# glibc builds, matching the distroless (Debian) runtime below.
FROM node:${NODE_VERSION}-slim AS build

ARG FRONTEND_REPO=https://github.com/yagan93/auth_portal.git
ARG FRONTEND_REF=main
ARG NEXT_PUBLIC_API_URL=https://api.docker.localhost

ENV NEXT_PUBLIC_API_URL=${NEXT_PUBLIC_API_URL} \
    NEXT_TELEMETRY_DISABLED=1

WORKDIR /app
ADD ${FRONTEND_REPO}#${FRONTEND_REF} .

# The repo uses pnpm (pnpm-lock.yaml); package.json pins no packageManager,
# so install pnpm directly instead of relying on corepack.
RUN npm install -g pnpm@10

# Upstream next.config.ts sets no options; switch on the standalone output so
# the runtime image only needs the pruned server bundle, not node_modules.
# The grep fails the build loudly if the upstream config shape ever changes.
RUN sed -i 's/const nextConfig: NextConfig = {/const nextConfig: NextConfig = {\n  output: "standalone",/' next.config.ts \
    && grep -q '"standalone"' next.config.ts

RUN pnpm install --frozen-lockfile
RUN pnpm build

# ---- Runtime stage: distroless — node binary only, no shell/npm, non-root ---
FROM gcr.io/distroless/nodejs${NODE_VERSION}-debian12:nonroot AS runtime

ENV NODE_ENV=production \
    NEXT_TELEMETRY_DISABLED=1 \
    PORT=3000 \
    HOSTNAME=0.0.0.0

WORKDIR /app

# distroless :nonroot runs as uid/gid 65532
COPY --from=build --chown=65532:65532 /app/.next/standalone ./
COPY --from=build --chown=65532:65532 /app/.next/static ./.next/static
COPY --from=build --chown=65532:65532 /app/public ./public

EXPOSE 3000

# The distroless image's entrypoint is the node binary itself
CMD ["server.js"]
