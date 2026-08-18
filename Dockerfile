# syntax=docker/dockerfile:1
# Stage 1: build | GraalVM native-image (multi-arch; CI builds each
# architecture natively — amd64 with -march=x86-64-v3, plus arm64 — and
# merges them into one manifest list)
# Digest-pinned (Renovate bumps it via PR): CI's buildhash skip means a
# floating tag would silently freeze on whatever it resolved to at the last
# rebuild — the pin turns base-image updates into explicit Dockerfile edits,
# which change the buildhash and trigger a rebuild.
#
# LAYER ORDER = INVALIDATION ORDER, rarest-changing first:
#   tools -> build config (build.gradle/settings.gradle) -> dependency jars
#   -> helper script -> src -> reachability metadata -> nativeCompile
#   -> strip -> healthcheck.
# A src-only edit reuses everything through the multi-hundred-MB dependency
# layer; only the ~2s metadata step and the (irreducibly slow, non-
# incremental) native compile re-run. CI builds are cold either way, so this
# order pays off in local `docker compose build` loops — and it is the
# prerequisite for a future BuildKit registry cache to be worth adding.
FROM ghcr.io/graalvm/native-image-community:25@sha256:0d936f32bb8acb5bc60c41b33e05f064d7a6aaf36b726538296c54949bd4a3c0 AS builder
LABEL authors="Beat,Oli,Sämi"

## Tooling — invalidated only by editing these lines (or the base pin).
## unzip stays even if the Gradle install changes: gen-reachability-metadata.sh
## lists jar entries with `unzip -Z1`.
RUN microdnf install -y unzip wget binutils && microdnf clean all
## One layer for fetch+unpack+link+delete: the ~135 MB distribution zip must
## not persist as a dead layer in every cache.
ARG GRADLE_VERSION=9.0.0
RUN wget -q https://services.gradle.org/distributions/gradle-${GRADLE_VERSION}-bin.zip -O /tmp/gradle.zip \
 && unzip -q /tmp/gradle.zip -d /opt \
 && ln -s /opt/gradle-${GRADLE_VERSION}/bin/gradle /usr/local/bin/gradle \
 && rm /tmp/gradle.zip

WORKDIR /build

## Build configuration — everything from here through the dependency layer is
## keyed ONLY on build.gradle/settings.gradle content and must stay above
## `COPY src/`: that is what lets a src-only change reuse the dependency
## layer below.
COPY build.gradle settings.gradle ./

## GraalVM native-image configuration + dependency-priming task.
RUN sed -i "/id 'org.springframework.boot'/a id 'org.graalvm.buildtools.native' version '1.1.0'" build.gradle
RUN cat >> build.gradle <<'EOF'

graalvmNative {
    binaries {
        named('main') {
            imageName = 'usr-srv'
            // Mostly-static: everything except glibc is linked statically.
            // Fully-static musl (--libc=musl) is amd64-only tooling; the
            // distroless runtime stage provides glibc at run time.
            buildArgs.add('--static-nolibc')
            buildArgs.add('-Os')  // optimize for binary size
            if (project.hasProperty('march') && project.property('march')) {
                buildArgs.add("-march=${project.property('march')}")
            }
        }
    }
}

// Dependency priming (run below, while src/ is still absent, so the layer is
// keyed on build config alone). `gradle dependencies` only resolves graphs
// and POMs — walking .incoming.files is what downloads the jars; and
// `compileJava` without src/ is skipped as NO-SOURCE, hence this task.
// Explicit allowlist; test configurations are excluded on purpose (never
// nativeCompile inputs, they would only bloat the layer). NO try/catch
// around the resolution: a transient Maven Central failure MUST fail the
// build — rescuing it would bake a silently-thin dependency layer. Every
// dependency is exact-pinned, so a failure here is a network blip, never
// resolution ambiguity. Lazy registration (configuration-avoidance): zero
// effect on `clean nativeCompile`.
tasks.register('primeDependencies') {
    doLast {
        def mustHave = ['compileClasspath', 'runtimeClasspath', 'annotationProcessor']
        def prefixes = ['nativeImage', 'nativeCompile', 'aot']
        // The prefix match would also catch aotTest*/nativeImageTest* — the
        // explicit test filter keeps test-only deps out of the layer.
        def primed = configurations.findAll { c ->
            c.canBeResolved && !c.name.toLowerCase().contains('test') &&
                (mustHave.contains(c.name) || prefixes.any { p -> c.name.startsWith(p) })
        }
        def missing = mustHave.findAll { n -> primed.every { it.name != n } }
        if (!missing.isEmpty()) {
            // A Gradle/plugin upgrade renamed or locked a required
            // configuration: fail loudly instead of baking a thin layer.
            throw new GradleException("primeDependencies: required configurations not resolvable: ${missing}")
        }
        primed.each { c ->
            // .incoming.files, not the legacy Configuration.resolve():
            // same downloads and same hard-fail on error, Gradle-10-safe.
            def files = c.incoming.files.files
            println "primed ${c.name}: ${files.size()} files"
        }
    }
}
EOF

## Dependency layer: populates /root/.gradle/caches (multi-hundred MB),
## reused verbatim on every src-only change. Also satisfies
## gen-reachability-metadata.sh's hard precondition: jjwt-impl/jjwt-jackson
## are implementation deps, so resolving compile/runtimeClasspath lands them
## in the cache (the script exits 1 if they are missing — the integrity
## check that this layer is real). nativeCompile may still fetch small
## extras via detached configurations (e.g. the GraalVM reachability-
## metadata repository archive) — a few MB, never staleness.
RUN gradle --no-daemon primeDependencies

## Helper script: BELOW the dependency layer (a script edit must never
## re-trigger the download), above src so everything under `COPY src/` is
## purely src-triggered work.
COPY build-helper/gen-reachability-metadata.sh ./scripts/

## Sources — the most frequent invalidation trigger; everything below re-runs
## on every src edit.
COPY src/ ./src/

## Reachability metadata (~2s): must stay after BOTH the dependency layer
## (reads the jjwt jars from /root/.gradle/caches, exits 1 otherwise) and
## `COPY src/` (it writes into src/main/resources/META-INF/native-image/).
RUN sh scripts/gen-reachability-metadata.sh

## NATIVE_MARCH selects the target microarchitecture level per build
## (CI passes x86-64-v3 on the amd64 leg; empty = GraalVM's default).
## Declared at its consumer: a changed value busts only the RUN below.
ARG NATIVE_MARCH=
# /build/build/native/nativeCompile/usr-srv | image name + flags from build.gradle
# `clean` + native-image is non-incremental: a real src change always pays the
# full compile; no ordering reduces this. There is no separate compileJava
# step anymore — `clean` deleted its output anyway, and its only real job
# (downloading dependencies) moved to primeDependencies. A Java compile error
# now surfaces inside this RUN's early javac phase, still well before
# native-image starts; don't reinstate compileJava "for safety".
RUN gradle --no-daemon clean nativeCompile ${NATIVE_MARCH:+-Pmarch=$NATIVE_MARCH}

# Strip the symbol table from the static binary to shave more size.
RUN strip /build/build/native/nativeCompile/usr-srv

# Health probe for the runtime image: no shell/curl there, so the compose
# healthcheck execs this tiny C binary instead (dynamic against glibc, which
# the distroless runtime provides). Kept below the native build so probe
# tweaks don't bust the expensive nativeCompile cache. (Deliberately NOT a
# parallel BuildKit stage: that would shave only ~2s of gcc off the tail at
# the price of a third stage — keep it linear, keep it last.)
COPY build-helper/healthcheck.c ./scripts/
RUN gcc -Os -o /healthcheck scripts/healthcheck.c && strip /healthcheck

# Stage 2: runtime | distroless base = glibc + CA certs + nonroot user, no
# shell. (scratch needs a fully-static binary; GraalVM's musl-static tooling
# is amd64-only and this image must run on the arm64 server.)
# Digest-pinned, same rationale as the builder stage above.
FROM gcr.io/distroless/base-debian12:nonroot@sha256:6c806311d31c11d364a8d13a022af5a48f29e43bd585ad6b51f1bb447f83d239
## Image identity, threaded in from Gradle via docker-bake.hcl (build args) so the
## version baked into the image matches the code version and the image tag.
## Consumed only by the LABELs — config-only, never busts a layer.
ARG VERSION=dev
ARG IMAGE_NAME=user-mgmt-service
LABEL org.opencontainers.image.title="${IMAGE_NAME}" \
      org.opencontainers.image.version="${VERSION}"
COPY --from=builder /healthcheck /healthcheck
COPY --from=builder /build/build/native/nativeCompile/usr-srv /usr-srv

# distroless :nonroot already runs as uid/gid 65532 and has a writable /tmp
ENTRYPOINT ["/usr-srv"]
