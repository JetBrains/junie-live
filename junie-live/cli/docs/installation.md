# Installation, build, and prerequisites

## Prerequisites

- **`hermes` and `junie` on `PATH`.** `junie-live` only *checks* for them at
  startup — it never installs or updates either product. When either is missing
  (or, once a floor is set, too old), startup prints actionable install/upgrade
  guidance and exits non-zero. Point `hermes.command` / `junie.command` at
  explicit paths in your config if they are not on `PATH`.
- **A Go 1.22+ toolchain** if you build from source.
- **`git`** on `PATH` for repository preparation.

### Version guidance

- The CLI's own version is stamped into `internal/version.Version` at build
  time via `-ldflags` (see `scripts/build-release.sh`); an unstamped local build
  reports `dev`. Print it with `junie-live --version`.
- Hermes/Junie compatibility: this release does not yet pin a minimum Hermes
  version (`internal/hermes.MinVersion` is empty). When a real compatibility
  floor is established, set that constant and document it here; startup will then
  reject older tools with a clear message.
- Each run records the exact CLI, Hermes, and Junie versions plus the validated
  embedded asset versions/hashes in `runs/<run-id>/manifest.json`, so any run is
  reproducible after the fact.

## Build from source

```bash
cd junie-live/cli
bash scripts/build.sh                 # sync assets, then build the CLI
bash scripts/run.sh --help            # sync assets, then run the CLI
```

## Install a release

Production releases provide Linux, macOS, and Windows binaries for amd64 and
arm64. Install the latest binary into `~/.junie-live/bin` with:

```bash
curl -fsSL https://raw.githubusercontent.com/JetBrains/junie-live/main/install-junie-live.sh | bash
```

The same release tag and target matrix are used for the Yana and Junie Live
CLIs, but each has its own explicit installer. To install Yana instead, use
`install-yana.sh` from the same repository.

## Release artifacts

`scripts/build-release.sh` produces version-stamped, statically-linked
(`CGO_ENABLED=0`, `-trimpath`) CLI binaries:

```bash
bash junie-live/cli/scripts/build-release.sh            # host platform → dist/
VERSION=1.2.3 bash junie-live/cli/scripts/build-release.sh
bash junie-live/cli/scripts/build-release.sh --cross    # linux/macos/windows × amd64/arm64
```

Artifacts land in `dist/` (git-ignored).

## Verifying a build

```bash
bash junie-live/cli/scripts/check.sh
```

runs `gofmt` (must be clean), `go vet ./...`, the full `go test ./...` (unit +
integration + embedded-asset consistency), and a release build. See
[`real-scenarios.md`](real-scenarios.md) for the opt-in real host-tool
scenarios. The mandated full `junie-live` Docker verification
(`junie-live/scripts/verify-docker.sh`) is run separately (by the parent).
