# syntax=docker/dockerfile:1
# Stage 1: build | GraalVM native-image (multi-arch; CI builds each
# architecture natively — amd64 with -march=x86-64-v3, plus arm64 — and
# merges them into one manifest list)
FROM ghcr.io/graalvm/native-image-community:25 AS builder
LABEL authors="Beat,Oli,Sämi"

## Dependencies
ARG GRADLE_VERSION=9.0.0
RUN microdnf install -y unzip wget binutils && microdnf clean all
RUN wget -q https://services.gradle.org/distributions/gradle-${GRADLE_VERSION}-bin.zip -O /tmp/gradle.zip
RUN unzip -q /tmp/gradle.zip -d /opt
RUN ln -s /opt/gradle-${GRADLE_VERSION}/bin/gradle /usr/local/bin/gradle

## Sources
WORKDIR /build
COPY build.gradle settings.gradle ./
COPY build-helper/gen-reachability-metadata.sh ./scripts/
COPY src/ ./src/

## GraalVM native-image configuration.
## NATIVE_MARCH selects the target microarchitecture level per build
## (CI passes x86-64-v3 on the amd64 leg; empty = GraalVM's default).
ARG NATIVE_MARCH=
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
EOF

# Resolve dependencies for native build
RUN gradle --no-daemon compileJava
RUN sh scripts/gen-reachability-metadata.sh

# /build/build/native/nativeCompile/usr-srv | image name + flags from build.gradle
RUN gradle --no-daemon clean nativeCompile ${NATIVE_MARCH:+-Pmarch=$NATIVE_MARCH}

# Strip the symbol table from the static binary to shave more size.
RUN strip /build/build/native/nativeCompile/usr-srv

# Health probe for the runtime image: no shell/curl there, so the compose
# healthcheck execs this tiny C binary instead (dynamic against glibc, which
# the distroless runtime provides). Kept below the native build so probe
# tweaks don't bust the expensive nativeCompile cache.
COPY build-helper/healthcheck.c ./scripts/
RUN gcc -Os -o /healthcheck scripts/healthcheck.c && strip /healthcheck

# Stage 2: runtime | distroless base = glibc + CA certs + nonroot user, no
# shell. (scratch needs a fully-static binary; GraalVM's musl-static tooling
# is amd64-only and this image must run on the arm64 server.)
FROM gcr.io/distroless/base-debian12:nonroot
## Image identity, threaded in from Gradle via docker-bake.hcl (build args) so the
## version baked into the image matches the code version and the image tag.
ARG VERSION=dev
ARG IMAGE_NAME=user-mgmt-service
LABEL org.opencontainers.image.title="${IMAGE_NAME}" \
      org.opencontainers.image.version="${VERSION}"
COPY --from=builder /healthcheck /healthcheck
COPY --from=builder /build/build/native/nativeCompile/usr-srv /usr-srv

# distroless :nonroot already runs as uid/gid 65532 and has a writable /tmp
ENTRYPOINT ["/usr-srv"]
