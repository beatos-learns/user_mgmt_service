# syntax=docker/dockerfile:1
# frontend/Dockerfile | containerize the Next.js auth portal (https://github.com/yagan93/auth_portal).
#
# The source is pulled straight from GitHub via BuildKit's git ADD, so this repo
# stays the single deployment entry point (no local clone needed):
#   docker compose build frontend
#
# NEXT_PUBLIC_API_URL is inlined into the client bundle at build time — rebuild
# the image to point the portal at a different backend URL.
#
# Layer order is deliberate (stable -> volatile): pnpm installs above the git
# ADD (upstream commits don't reinstall it), and the API-URL ARG/ENV sits
# directly above `pnpm build` (an URL change re-runs only the build). CI runs
# cold builds either way — the order pays off in local compose rebuilds and
# any future registry cache.

# ---- Build stage: install with pnpm and compile the production bundle -------
# Debian-based (not alpine) so any prebuilt native modules pnpm pulls in are
# glibc builds, matching the distroless (Debian) runtime below.
# Digest-pinned (Renovate bumps it via PR): CI's buildhash skip means a
# floating tag would silently freeze on whatever it resolved to at the last
# rebuild — the pin turns base-image updates into explicit Dockerfile edits,
# which change the buildhash and trigger a rebuild. Plain references (no ARG
# indirection) so Renovate can parse both FROM lines; the node MAJOR lives in
# this line AND the distroless runtime line below — bump them together.
FROM node:22-slim@sha256:6c74791e557ce11fc957704f6d4fe134a7bc8d6f5ca4403205b2966bd488f6b3 AS build

ARG FRONTEND_REPO=https://github.com/yagan93/auth_portal.git
ARG FRONTEND_REF=main

# Static — keeps telemetry off for every pnpm/next invocation in this stage.
# (The volatile NEXT_PUBLIC_API_URL is deliberately NOT set here: an ENV busts
# every layer after it, and only `pnpm build` consumes the URL — see below.)
ENV NEXT_TELEMETRY_DISABLED=1

# The repo uses pnpm (pnpm-lock.yaml); package.json pins no packageManager,
# so install pnpm directly instead of relying on corepack. Exact-pinned
# (Renovate, npm datasource — see renovate.json); majors are held back
# deliberately: a new pnpm major can change install defaults/behavior against
# upstream's lockfile (the v9.0 lockfile FORMAT itself spans pnpm 9-11) —
# bump manually after testing a frontend build.
# Deliberately ABOVE the git ADD: this layer keys only on the base image +
# the version string, so upstream commits never reinstall pnpm.
RUN npm install -g pnpm@10.34.5

WORKDIR /app
# BuildKit's git-remote ADD has no COPY equivalent — DL3020 is a false positive here.
# Cache-keyed on the RESOLVED commit: CI passes a full 40-char SHA; local
# compose builds pass `main` (re-resolved via ls-remote on every build).
# hadolint ignore=DL3020
ADD ${FRONTEND_REPO}#${FRONTEND_REF} .

RUN pnpm install --frozen-lockfile

# Upstream next.config.ts sets no options; switch on the standalone output so
# the runtime image only needs the pruned server bundle, not node_modules.
# The grep fails the build loudly if the upstream config shape ever changes.
# Below `pnpm install` on purpose (install never reads next.config.ts): a
# recipe tweak here re-runs only sed + build, never the install.
RUN sed -i 's/const nextConfig: NextConfig = {/const nextConfig: NextConfig = {\n  output: "standalone",/' next.config.ts \
    && grep -q '"standalone"' next.config.ts

# Declared this low on purpose: only `pnpm build` consumes the URL (Next.js
# inlines NEXT_PUBLIC_* into the client bundle at build time), so changing
# the NEXT_PUBLIC_API_URL var re-runs nothing above this line.
ARG NEXT_PUBLIC_API_URL=https://api.docker.localhost
ENV NEXT_PUBLIC_API_URL=${NEXT_PUBLIC_API_URL}

RUN pnpm build

# ---- Runtime stage: distroless — node binary only, no shell/npm, non-root ---
# Digest-pinned, same rationale as the build stage. The node major is part of
# the repo NAME here (nodejs22), so Renovate only bumps the digest; move to a
# new node major by editing both FROM lines in one commit.
FROM gcr.io/distroless/nodejs22-debian12:nonroot@sha256:13593b7570658e8477de39e2f4a1dd25db2f836d68a0ba771251572d23bb4f8e AS runtime

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
