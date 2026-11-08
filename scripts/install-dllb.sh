#!/usr/bin/env bash
#
# install-dllb.sh -- install the `dllb-server` binary that Ragex's per-project
# knowledge-graph daemon spawns.
#
# `yoke` embeds Ragex, and Ragex's `:per_project` store backend launches a
# `dllb-server` OS process against `<project>/.ragex/dllb.redb`. That binary is
# a Rust executable and is *not* part of the Elixir dependency tree, so a fresh
# machine -- including every GitHub Actions runner -- has no `dllb-server` in
# `PATH` and Ragex degrades to the (slower) ETS backend with:
#
#   Failed to initialize per-project dllb instance for <dir>: :dllb_binary_not_found
#
# Used by `action.yml`, and usable standalone:
#
#   ./scripts/install-dllb.sh                    # latest release
#   DLLB_VERSION=v1.0.2 ./scripts/install-dllb.sh
#   DLLB_INSTALL_DIR=/usr/local/bin ./scripts/install-dllb.sh
#
# Design constraints (same as scripts/install.sh):
#   * No `sudo`. Installs into $HOME/.local/bin by default.
#   * No compilation. The release ships a prebuilt tarball.
#   * The SHA-256 from the release's SHA256SUMS is verified *before* the binary
#     is made executable, so a corrupted or tampered download can never run.
#   * Never fails the caller's job by default: dllb is an *accelerator*, and a
#     review that would merely have been slower must not fail because it was
#     unavailable. Pass DLLB_REQUIRED=1 to opt into failing instead.
#
set -euo pipefail

REPO="${DLLB_REPO:-Oeditus/dllb}"
VERSION="${DLLB_VERSION:-}"
INSTALL_DIR="${DLLB_INSTALL_DIR:-$HOME/.local/bin}"
REQUIRED="${DLLB_REQUIRED:-0}"

log() { printf '%s\n' "$*" >&2; }

# `fail` aborts when the caller opted in to requiring dllb, and merely warns
# otherwise -- the caller's job keeps running on the ETS backend.
fail() {
  if [ "$REQUIRED" = "1" ]; then
    printf 'error: %s\n' "$*" >&2
    exit 1
  fi
  printf 'warning: %s\n' "$*" >&2
  printf 'warning: continuing without dllb-server; Ragex will use the ETS backend.\n' >&2
  exit 0
}

need() {
  command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

need curl
need sha256sum
need tar

# Retry transient HTTP failures, but bound both each attempt and total retries.
download() {
  curl -fsSL --retry 3 --retry-delay 2 --retry-max-time 90 \
    --connect-timeout 10 --max-time 30 "$@"
}

case "$(uname -s)" in
  Linux)  os="unknown-linux-gnu" ;;
  Darwin) os="apple-darwin" ;;
  *)      fail "unsupported operating system: $(uname -s)" ;;
esac

case "$(uname -m)" in
  x86_64|amd64) arch="x86_64" ;;
  arm64|aarch64) arch="aarch64" ;;
  *) fail "unsupported architecture: $(uname -m)" ;;
esac

# The release does not publish an x86_64 macOS build.
if [ "$os" = "apple-darwin" ] && [ "$arch" = "x86_64" ]; then
  fail "dllb does not publish x86_64-apple-darwin binaries"
fi

target="${arch}-${os}"

if [ -z "$VERSION" ]; then
  log "Resolving the latest dllb release…"
  VERSION="$(
    download "https://api.github.com/repos/${REPO}/releases/latest" \
      | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
      | head -n1
  )" || fail "could not resolve the latest release of ${REPO}"
  [ -n "$VERSION" ] || fail "could not determine the latest release of ${REPO}"
fi

archive="dllb-${VERSION}-${target}.tar.gz"
base="https://github.com/${REPO}/releases/download/${VERSION}"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

log "Downloading dllb ${VERSION} for ${target}…"
download "${base}/${archive}" -o "${tmp}/${archive}" || fail "download failed: ${base}/${archive}"
download "${base}/SHA256SUMS" -o "${tmp}/SHA256SUMS" || fail "download failed: ${base}/SHA256SUMS"

log "Verifying checksum…"
# SHA256SUMS is `sha256sum` output, i.e. "<hash>  <filename>". Match the
# archive by name so the manifest cannot be satisfied by a different asset.
expected="$(awk -v f="$archive" '$2 == f {print $1}' "${tmp}/SHA256SUMS")"
actual="$(sha256sum "${tmp}/${archive}" | awk '{print $1}')"

[ -n "$expected" ] || fail "no checksum for ${archive} in SHA256SUMS"
if [ "$expected" != "$actual" ]; then
  fail "checksum mismatch for ${archive}: expected ${expected}, got ${actual}"
fi

log "Extracting…"
tar -xzf "${tmp}/${archive}" -C "${tmp}"
src="${tmp}/dllb-${VERSION}-${target}/dllb-server"
[ -f "$src" ] || fail "dllb-server missing from ${archive}"

mkdir -p "$INSTALL_DIR"
install -m 0755 "$src" "${INSTALL_DIR}/dllb-server"

log "Installed dllb-server ${VERSION} to ${INSTALL_DIR}/dllb-server"

case ":${PATH}:" in
  *":${INSTALL_DIR}:"*) ;;
  *) log "note: ${INSTALL_DIR} is not on PATH; add it to use 'dllb-server' directly." ;;
esac
