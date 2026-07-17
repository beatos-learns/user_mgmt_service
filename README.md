Spring 4.1 compliant app that demonstrates the authentication and authorization of a user via JWT

## Build & deploy

Every push to `main` (and every `v*` tag) runs `.github/workflows/deploy.yaml`:
it builds the backend (GraalVM native image, amd64 + arm64) and the Next.js
auth portal, publishes them to GHCR, and deploys the compose stack to
auth.niichan.ch.

Builds are content-addressed ("buildhash"): an image is only rebuilt when its
build inputs actually changed — otherwise the run re-points `:<version>` at the
already-published image and goes straight to deploy (~2 min instead of ~8).
Details, hash inputs, and the maintenance rule live in `deploy.yaml` (header
plus the "Compute buildhashes" step comment). To force a rebuild anyway:
Actions → Build & Deploy → Run workflow → `force_rebuild`.

Base images are digest-pinned and `renovate.json` keeps them (plus pnpm and
Gradle) fresh via PRs (image digests and Gradle arrive grouped) — merging a
PR that touches a Dockerfile changes the buildhash and triggers the rebuild.
