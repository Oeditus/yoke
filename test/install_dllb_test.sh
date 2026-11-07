#!/usr/bin/env bash
#
# test/install_dllb_test.sh
#
# Tests for `scripts/install-dllb.sh`, the installer that provides the
# `dllb-server` binary Ragex's per-project store backend spawns.
#
# The installer is deliberately *non-fatal*: dllb is an accelerator, and a
# review that would merely have been slower must not fail because the binary
# was unavailable. These tests pin that contract, plus the checksum
# verification that makes a tampered download unrunnable.
#
# Network is never touched: every case points the installer at a `file://`
# URL or an unreachable version tag, and the download path is exercised
# against a locally-built tarball.
#
# Usage:
#   bash test/install_dllb_test.sh
#
# Exit code 0 on success, 1 on any failure.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
INSTALLER="${PROJECT_ROOT}/scripts/install-dllb.sh"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

failures=0
pass() { echo "  ✓ $1"; }
fail() { echo "  ✗ $1"; failures=$((failures + 1)); }

echo "== dllb install script tests =="

if [ ! -x "$INSTALLER" ]; then
  fail "scripts/install-dllb.sh is missing or not executable"
  echo "❌ ${failures} dllb install test(s) failed."
  exit 1
fi

# ---------------------------------------------------------------
echo "Test 1: a failed download warns and exits 0 (never fails the job)"
# ---------------------------------------------------------------
out="$(
  DLLB_VERSION=v0.0.0-does-not-exist \
  DLLB_INSTALL_DIR="${WORK_DIR}/t1" \
    "$INSTALLER" 2>&1
)"
status=$?

if [ "$status" -eq 0 ]; then
  pass "exits 0 when the download fails"
else
  fail "expected exit 0, got ${status}"
fi

if printf '%s' "$out" | grep -q "continuing without dllb-server"; then
  pass "explains the degradation to the ETS backend"
else
  fail "expected a 'continuing without dllb-server' notice"
fi

# ---------------------------------------------------------------
echo "Test 2: DLLB_REQUIRED=1 opts into failing"
# ---------------------------------------------------------------
DLLB_VERSION=v0.0.0-does-not-exist \
DLLB_REQUIRED=1 \
DLLB_INSTALL_DIR="${WORK_DIR}/t2" \
  "$INSTALLER" >/dev/null 2>&1
status=$?

if [ "$status" -eq 1 ]; then
  pass "exits 1 when DLLB_REQUIRED=1"
else
  fail "expected exit 1 with DLLB_REQUIRED=1, got ${status}"
fi

# ---------------------------------------------------------------
echo "Test 3: checksum mismatch refuses to install"
# ---------------------------------------------------------------
# Build a fake release: an archive plus a SHA256SUMS that names the wrong hash.
fake="${WORK_DIR}/fake-release"
mkdir -p "${fake}/dllb-v9.9.9-x86_64-unknown-linux-gnu"
echo "#!/bin/sh" > "${fake}/dllb-v9.9.9-x86_64-unknown-linux-gnu/dllb-server"
chmod +x "${fake}/dllb-v9.9.9-x86_64-unknown-linux-gnu/dllb-server"

archive="dllb-v9.9.9-x86_64-unknown-linux-gnu.tar.gz"
tar -czf "${fake}/${archive}" -C "${fake}" "dllb-v9.9.9-x86_64-unknown-linux-gnu"

# A deliberately wrong hash: the installer must refuse before `install -m 0755`.
printf '%s  %s\n' \
  "0000000000000000000000000000000000000000000000000000000000000000" \
  "$archive" > "${fake}/SHA256SUMS"

# Point the installer at the fake release by overriding the URL prefix it
# builds. It derives both URLs from `base`, so a file:// base is enough.
DLLB_VERSION=v9.9.9 \
DLLB_INSTALL_DIR="${WORK_DIR}/t3" \
DLLB_REPO="file://${fake}" \
DLLB_BASE_URL="file://${fake}" \
  "$INSTALLER" >/dev/null 2>&1
status=$?

if [ -f "${WORK_DIR}/t3/dllb-server" ]; then
  fail "installed a binary whose checksum did not match"
else
  pass "refused to install a checksum-mismatched archive"
fi

# ---------------------------------------------------------------
echo "Test 4: the installer verifies before making the binary executable"
# ---------------------------------------------------------------
# The checksum is computed over the archive and compared before `install -m
# 0755` runs, so a mismatch can never leave an executable behind. Test 3
# asserts the absence; this asserts the ordering is not accidental by
# checking the script's own source.
if grep -q 'checksum mismatch' "$INSTALLER" &&
   [ "$(grep -n 'checksum mismatch' "$INSTALLER" | cut -d: -f1)" -lt \
     "$(grep -n 'install -m 0755' "$INSTALLER" | cut -d: -f1)" ]; then
  pass "checksum verification precedes install -m 0755"
else
  fail "checksum verification must precede the install step"
fi

# ---------------------------------------------------------------
echo "Test 5: unsupported platform is reported, not silently skipped"
# ---------------------------------------------------------------
# `uname` cannot be faked without a wrapper, so assert the guard exists.
if grep -q 'unsupported operating system' "$INSTALLER" &&
   grep -q 'unsupported architecture' "$INSTALLER"; then
  pass "guards unsupported OS/arch"
else
  fail "expected explicit unsupported-platform guards"
fi

echo
if [ "$failures" -eq 0 ]; then
  echo "✅ All dllb install tests passed."
  exit 0
else
  echo "❌ ${failures} dllb install test(s) failed."
  exit 1
fi
