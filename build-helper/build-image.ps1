# build-image.ps1 | build the native, zstd-compressed image tagged from Gradle
# Extra args are forwarded to `docker buildx bake`
#   .\build-image.ps1            # build user-mgmt-service:<version> locally
#   .\build-image.ps1 --push     # build and push the zstd layers to a registry
# Lints the Dockerfile with hadolint before building; bypass with: $env:SKIP_LINT=1
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Set-Location -Path $root

# Lint the Dockerfile
if (-not $env:SKIP_LINT) {
    Write-Host "Linting Dockerfile (hadolint)..."
    docker run --rm -v "${root}:/repo" hadolint/hadolint hadolint --config /repo/.hadolint.yaml /repo/Dockerfile
    if ($LASTEXITCODE -ne 0) { throw "hadolint found issues (exit $LASTEXITCODE). Fix them, or bypass with `$env:SKIP_LINT=1." }
    Write-Host "Dockerfile lint clean."
}

# Build the image
$name = (Select-String -Path "$root\settings.gradle" -Pattern "rootProject\.name\s*=\s*'([^']+)'").Matches[0].Groups[1].Value
$version = (Select-String -Path "$root\build.gradle" -Pattern "^\s*version\s*=\s*'([^']+)'").Matches[0].Groups[1].Value
if ([string]::IsNullOrWhiteSpace($name))    { throw "Could not read rootProject.name from settings.gradle" }
if ([string]::IsNullOrWhiteSpace($version)) { throw "Could not read version from build.gradle" }

Write-Host "Building ${name}:${version} (GraalVM native, zstd layers)..."
$env:IMAGE_NAME = $name
$env:VERSION    = $version
docker buildx bake @args
if ($LASTEXITCODE -ne 0) { throw "docker buildx bake failed (exit $LASTEXITCODE)." }

# Report the size of the image
$ref = "${name}:${version}"
$sizeBytes = docker image inspect $ref --format '{{.Size}}' 2>$null
if ($sizeBytes -match '^\d+$') {
    $compressedMB = [math]::Round([int64]$sizeBytes / 1MB, 1)
    $uncompressed = docker images $ref --format '{{.Size}}' 2>$null | Select-Object -First 1
    Write-Host ("Image {0}: {1} MB compressed on disk (uncompressed {2})." -f $ref, $compressedMB, $uncompressed)
} else {
    Write-Host "Built ${ref} (size unavailable - image not in local store, e.g. --push only)."
}
