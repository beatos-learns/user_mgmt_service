# syntax=docker/dockerfile:1
# Stage 1: build | GraalVM + musl static toolchain
FROM ghcr.io/graalvm/native-image-community:25-muslib AS builder
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
RUN sed -i "/id 'org.springframework.boot'/a id 'org.graalvm.buildtools.native' version '1.1.0'" build.gradle
RUN cat >> build.gradle <<'EOF'

graalvmNative {
    binaries {
        named('main') {
            imageName = 'usr-srv'
            buildArgs.add('--static')
            buildArgs.add('--libc=musl')
            buildArgs.add('-Os')  // optimize for binary size
        }
    }
}
EOF

# Resolve dependencies for native build
RUN gradle --no-daemon compileJava
RUN sh scripts/gen-reachability-metadata.sh

# /build/build/native/nativeCompile/usr-srv | image name + flags from build.gradle
RUN gradle --no-daemon clean nativeCompile

# Strip the symbol table from the static binary to shave more size.
RUN strip /build/build/native/nativeCompile/usr-srv

# Minimal rootfs for the scratch image: a non-root user + a writable /tmp.
RUN mkdir -p /rootfs/etc /rootfs/tmp
RUN printf 'app:x:1000:1000::/tmp:/sbin/nologin\n' > /rootfs/etc/passwd
RUN printf 'app:x:1000:\n' > /rootfs/etc/group
RUN chmod 1777 /rootfs/tmp

# Health probe for the scratch image: no shell/curl there, so the compose
# healthcheck execs this tiny musl-static binary instead. Kept below the
# native build so probe tweaks don't bust the expensive nativeCompile cache.
COPY build-helper/healthcheck.c ./scripts/
RUN x86_64-linux-musl-gcc -Os -static -o /rootfs/healthcheck scripts/healthcheck.c && strip /rootfs/healthcheck

# Stage 2: runtime  | scratch = nothing
FROM scratch
## Image identity, threaded in from Gradle via docker-bake.hcl (build args) so the
## version baked into the image matches the code version and the image tag.
ARG VERSION=dev
ARG IMAGE_NAME=user-mgmt-service
LABEL org.opencontainers.image.title="${IMAGE_NAME}" \
      org.opencontainers.image.version="${VERSION}"
COPY --from=builder /rootfs/ /
COPY --from=builder /build/build/native/nativeCompile/usr-srv /usr-srv

USER 1000:1000
ENTRYPOINT ["/usr-srv"]
