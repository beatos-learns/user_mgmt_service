# docker-bake.hcl | build the GraalVM native image with zstd-compressed layers.
# zstd layers run directly on a daemon with the containerd image store.
#
# The tags below serve LOCAL builds. CI (deploy.yaml) overrides them via
# `set:` to a per-arch content tag (:bh-<buildhash>-<arch>) and passes
# VERSION=bh-<buildhash>, so the OCI version label identifies the image
# CONTENT — release tags (:<version>/:latest) are separate manifest lists
# created by the merge-manifests job, re-pointable without rebuilding.

variable "IMAGE_NAME" {
  default = "user-mgmt-service"
}

variable "VERSION" {
  default = "dev"
}

group "default" {
  targets = ["app"]
}

target "app" {
  context    = "."
  dockerfile = "Dockerfile"

  # Thread identity into the image (used for OCI labels in the Dockerfile).
  args = {
    VERSION    = "${VERSION}"
    IMAGE_NAME = "${IMAGE_NAME}"
  }

  tags = [
    "${IMAGE_NAME}:${VERSION}",
    "${IMAGE_NAME}:latest",
  ]

  # Native zstd layer compression. force-compression re-packs cached/base layers
  # (otherwise gzip) as zstd too. Stores into the local image store
  # `--push` to push zstd layers to a registry
  output = ["type=image,compression=zstd,compression-level=19,force-compression=true"]
}
