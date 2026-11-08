#!/usr/bin/env bash
#
# install.sh -- download a pinned `yoke` release binary and verify its checksum.
#
# Used by action.yml, and usable standalone:
#
#   ./scripts/install.sh                    # latest release
#   YOKE_VERSION=v0.21.1 ./scripts/install.sh
#   YOKE_INSTALL_DIR=/usr/local/bin ./scripts/install.sh
#
# Design constraints:
#   * No `sudo`. Installs into $HOME/.local/bin by default.
#   * No compilation. The escript is a single file; downloading it is seconds,
#     `mix deps.get && mix escript.build` is minutes.
#   * The checksum is verified before the binary is made executable, so a
#     corrupted or tampered download can never be run.
#
set -euo pipefail

REPO="${YOKE_REPO:-Oeditus/yoke}"
VERSION="${YOKE_VERSION:-}"
INSTALL_DIR="${YOKE_INSTALL_DIR:-$HOME/.local/bin}"
BIN_NAME="yoke"

log() { printf '%s\n' "$*" >&2; }
fail() { printf 'error: %s\n' "$*" >&2; exit 1; }

need() {
  command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

need curl
need sha256sum

download() {
  curl -fsSL --retry 3 --retry-delay 2 --retry-max-time 90 \
    --connect-timeout 10 --max-time 30 "$@"
}

case "$(uname -s)" in
  Linux)  os="linux" ;;
  Darwin) os="darwin" ;;
  *)      fail "unsupported operating system: $(uname -s)" ;;
esac

case "$(uname -m)" in
  x86_64|amd64) arch="x86_64" ;;
  arm64|aarch64) arch="aarch64" ;;
  *) fail "unsupported architecture: $(uname -m)" ;;
esac

# The release publishes a single portable escript; the asset name does not
# vary by OS/arch, but we keep the check above so an unsupported platform
# fails with a clear message rather than a confusing download error.
: "$os" "$arch"

if [ -z "$VERSION" ]; then
  log "Resolving the latest yoke release…"
  VERSION="$(
    download "https://api.github.com/repos/${REPO}/releases/latest" \
      | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
      | head -n1
  )" || fail "could not resolve the latest release of ${REPO}"
  [ -n "$VERSION" ] || fail "could not determine the latest release of ${REPO}"
fi

base="https://github.com/${REPO}/releases/download/${VERSION}"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

log "Downloading yoke ${VERSION}…"
download "${base}/${BIN_NAME}" -o "${tmp}/${BIN_NAME}" || fail "download failed: ${base}/${BIN_NAME}"
download "${base}/${BIN_NAME}.sha256" -o "${tmp}/${BIN_NAME}.sha256" || fail "download failed: ${base}/${BIN_NAME}.sha256"

log "Verifying checksum…"
# The published file is `sha256sum` output, i.e. "<hash>  <filename>". Compare
# only the hash so the filename in the manifest cannot cause a false match.
expected="$(awk '{print $1}' "${tmp}/${BIN_NAME}.sha256")"
actual="$(sha256sum "${tmp}/${BIN_NAME}" | awk '{print $1}')"

[ -n "$expected" ] || fail "checksum manifest is empty"
if [ "$expected" != "$actual" ]; then
  fail "checksum mismatch for ${BIN_NAME}: expected ${expected}, got ${actual}"
fi

mkdir -p "$INSTALL_DIR"
install -m 0755 "${tmp}/${BIN_NAME}" "${INSTALL_DIR}/${BIN_NAME}"

log "Installed yoke ${VERSION} to ${INSTALL_DIR}/${BIN_NAME}"

case ":${PATH}:" in
  *":${INSTALL_DIR}:"*) ;;
  *) log "note: ${INSTALL_DIR} is not on PATH; add it to use 'yoke' directly." ;;
esac
