#!/usr/bin/env bash
# Installer for the Junie Live CLI published by JetBrains/junie-live.
# Downloads the matching binary from GitHub Releases and installs it to
# ~/.junie-live/bin/.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/JetBrains/junie-live/main/install-junie-live.sh | bash
#   curl -fsSL https://raw.githubusercontent.com/JetBrains/junie-live/main/install-junie-live.sh | bash -s -- v0.123

set -euo pipefail

REPO="JetBrains/junie-live"
BINARY_NAME="junie-live"
INSTALL_DIR="$HOME/.${BINARY_NAME}/bin"
RELEASE_VERSION="${1:-${JUNIE_LIVE_VERSION:-latest}}"

# --- Helpers ---

info()  { printf '\033[1;34m%s\033[0m\n' "$*" >&2; }
error() { printf '\033[1;31mError: %s\033[0m\n' "$*" >&2; exit 1; }

detect_os() {
  case "$(uname -s)" in
    Linux*)  echo "linux" ;;
    Darwin*) echo "darwin" ;;
    MINGW*|MSYS*|CYGWIN*) echo "windows" ;;
    *) error "Unsupported operating system: $(uname -s)" ;;
  esac
}

detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64)  echo "amd64" ;;
    arm64|aarch64)  echo "arm64" ;;
    *) error "Unsupported architecture: $(uname -m)" ;;
  esac
}

# Fetch JSON from a GitHub API URL
api_get() {
  local url="$1"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$url"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO- "$url"
  else
    error "Neither curl nor wget found. Please install one of them."
  fi
}

# Resolve the latest release tag WITHOUT the GitHub API.
# The /releases/latest web URL 302-redirects to /releases/tag/<tag>; following
# that redirect and reading the final URL avoids api.github.com entirely, so it
# is not subject to the 60-req/hour unauthenticated rate limit (HTTP 403).
latest_tag_via_redirect() {
  local url="https://github.com/${REPO}/releases/latest"
  local effective="" tag=""
  if command -v curl >/dev/null 2>&1; then
    effective=$(curl -fsSLI -o /dev/null -w '%{url_effective}' "$url" 2>/dev/null) || return 1
  elif command -v wget >/dev/null 2>&1; then
    effective=$(wget -S --max-redirect=10 -O /dev/null "$url" 2>&1 \
      | grep -i '^[[:space:]]*Location:' | tail -1 | sed 's/.*Location:[[:space:]]*//' | tr -d '\r') || return 1
  else
    return 1
  fi
  # Final URL looks like https://github.com/<repo>/releases/tag/<tag>
  case "$effective" in
    */releases/tag/*) tag="${effective##*/releases/tag/}"; tag="${tag%%/*}" ;;
    *) return 1 ;;
  esac
  [ -n "$tag" ] || return 1
  echo "$tag"
}

# Fetch the tag name of the latest GitHub release
latest_tag() {
  info "Fetching latest release for ${REPO}..."
  local tag
  # Prefer the API-free redirect (no rate limit). Fall back to the public API.
  tag=$(latest_tag_via_redirect) || tag=""
  if [ -z "$tag" ]; then
    local url="https://api.github.com/repos/${REPO}/releases/latest"
    local json
    json=$(api_get "$url") || error "Could not fetch latest release. Check https://github.com/${REPO}/releases"
    tag=$(echo "$json" | grep '"tag_name"' | head -1 | sed 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
  fi
  [ -n "$tag" ] || error "Could not determine latest release tag. Check https://github.com/${REPO}/releases"
  info "Latest release: ${tag}"
  echo "$tag"
}

# Build the public download URL for a release asset by name
asset_download_url() {
  local tag="$1" asset_name="$2"
  echo "https://github.com/${REPO}/releases/download/${tag}/${asset_name}"
}

download() {
  local url="$1" dest="$2"
  info "  GET ${url}"
  # Download to a temporary sibling file and atomically move it into place.
  # Overwriting an existing code-signed Mach-O *in place* (same inode) breaks
  # macOS: the kernel still has the previous binary's code-signature pages
  # cached for that vnode, so the new bytes fail validation
  # ("load code signature error 2" / "rejecting invalid page") and the process
  # is SIGKILL'd even though the binary is perfectly valid.
  # A fresh temp file + rename gives a new inode, so no stale signature is cached.
  local tmp="${dest}.download.$$"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL -o "$tmp" "$url"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$tmp" "$url"
  fi
  chmod +x "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$dest"
  info "  Saved to ${dest} ($(wc -c < "$dest" | tr -d ' ') bytes)"
}

# --- Main ---

main() {
  local os arch tag asset_name download_url

  os=$(detect_os)
  arch=$(detect_arch)
  info "Detected platform: ${os}/${arch}"

  if [ "$RELEASE_VERSION" = "latest" ] || [ -z "$RELEASE_VERSION" ]; then
    tag=$(latest_tag)
  else
    tag="$RELEASE_VERSION"
    info "Selected release: ${tag}"
  fi

  info "Installing ${BINARY_NAME} ${tag} (${os}/${arch})..."

  asset_name="${BINARY_NAME}-${os}-${arch}"
  if [ "$os" = "windows" ]; then
    asset_name="${asset_name}.exe"
  fi

  download_url=$(asset_download_url "$tag" "$asset_name")

  mkdir -p "$INSTALL_DIR"

  local dest="${INSTALL_DIR}/${BINARY_NAME}"
  if [ "$os" = "windows" ]; then
    dest="${dest}.exe"
  fi

  info "Downloading ${download_url}..."
  download "$download_url" "$dest" || error "Download failed. Check that a release exists at https://github.com/${REPO}/releases"

  chmod +x "$dest"

  info "Installed to ${dest}"

  # Add to PATH if not already there
  if ! echo "$PATH" | tr ':' '\n' | grep -qx "$INSTALL_DIR"; then
    local shell_name
    shell_name=$(basename "${SHELL:-/bin/bash}")
    local profile=""
    case "$shell_name" in
      zsh)  profile="$HOME/.zshrc" ;;
      bash)
        if [ -f "$HOME/.bash_profile" ]; then
          profile="$HOME/.bash_profile"
        else
          profile="$HOME/.bashrc"
        fi
        ;;
      fish) profile="$HOME/.config/fish/config.fish" ;;
    esac

    local export_line="export PATH=\"${INSTALL_DIR}:\$PATH\""
    if [ "$shell_name" = "fish" ]; then
      export_line="set -gx PATH ${INSTALL_DIR} \$PATH"
    fi

    if [ -n "$profile" ]; then
      if ! grep -qF "$INSTALL_DIR" "$profile" 2>/dev/null; then
        printf '\n# %s CLI\n%s\n' "$BINARY_NAME" "$export_line" >> "$profile"
        info "Added ${INSTALL_DIR} to PATH in ${profile}"
        info "Run 'source ${profile}' or open a new terminal to use ${BINARY_NAME}."
      fi
    else
      info "Add the following to your shell profile:"
      info "  ${export_line}"
    fi
  fi

  info ""
  info "Done! Run '${BINARY_NAME} --help' to get started."
}

main "$@"
