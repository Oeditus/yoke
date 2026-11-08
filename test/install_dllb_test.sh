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
# Network is never touched: curl is replaced with a local release fixture.
# Also exercises the yoke installer, which shares the download policy.
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

mkdir -p "$WORK_DIR/bin"
export MOCK_CURL_LOG="$WORK_DIR/curl.log"
export MOCK_RELEASE="$WORK_DIR/fake-release"
export MOCK_CURL_MODE=fail

/bin/cat > "$WORK_DIR/bin/curl" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$MOCK_CURL_LOG"
url=
output=
while [ "$#" -gt 0 ]; do
  case "$1" in
    https://*) url="$1"; shift ;;
    -o) output="$2"; shift 2 ;;
    --retry|--retry-delay|--retry-max-time|--connect-timeout|--max-time) shift 2 ;;
    *) shift ;;
  esac
done
[ "$MOCK_CURL_MODE" != fail ] || exit 22
case "$url" in
  */releases/latest)
    [ "$MOCK_CURL_MODE" != empty ] || exit 0
    printf '%s\n' '{"tag_name":"v9.9.9"}'
    ;;
  *)
    [ -n "$output" ] || exit 2
    cp "$MOCK_RELEASE/${url##*/}" "$output"
    ;;
esac
MOCK
/bin/cat > "$WORK_DIR/bin/uname" <<'MOCK'
#!/usr/bin/env bash
case "$1" in
  -s) printf '%s\n' Linux ;;
  -m) printf '%s\n' x86_64 ;;
  *) exit 1 ;;
esac
MOCK
chmod +x "$WORK_DIR/bin/curl" "$WORK_DIR/bin/uname"
export PATH="$WORK_DIR/bin:$PATH"

failures=0
pass() { printf '  PASS %s\n' "$1"; }
fail() { printf '  FAIL %s\n' "$1"; failures=$((failures + 1)); }

echo "== dllb install script tests =="

if [ ! -x "$INSTALLER" ]; then
  fail "scripts/install-dllb.sh is missing or not executable"
  echo "${failures} installer test(s) failed."
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

# The mock curl serves real fixture bytes, so this reaches checksum validation.
out="$(
DLLB_VERSION=v9.9.9 \
DLLB_REQUIRED=1 \
DLLB_INSTALL_DIR="${WORK_DIR}/t3" \
MOCK_CURL_MODE=release \
  "$INSTALLER" 2>&1
)"
status=$?

if [ "$status" -eq 1 ] && [[ "$out" == *"checksum mismatch"* ]] &&
   [ ! -f "${WORK_DIR}/t3/dllb-server" ]; then
  pass "checksum-mismatched archive reaches validation and is rejected"
else
  fail "expected a checksum mismatch without installing a binary"
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

echo "Test 6: latest-release failure follows the optional/required contract"
for mode in fail empty; do
  for required in 0 1; do
    out="$(DLLB_VERSION='' DLLB_REQUIRED="$required" MOCK_CURL_MODE="$mode" \
      DLLB_INSTALL_DIR="$WORK_DIR/latest-$mode-$required" "$INSTALLER" 2>&1)"
    status=$?
    if [ "$status" -eq "$required" ] && [[ "$out" == *"latest release"* ]]; then
      pass "latest lookup $mode respects DLLB_REQUIRED=$required"
    else
      fail "latest lookup $mode returned $status with DLLB_REQUIRED=$required"
    fi
  done
done

echo "Test 7: verified dllb archive installs from pinned and latest versions"
# Manifests contain asset basenames, not absolute fixture paths.
hash="$(sha256sum "$fake/$archive" | awk '{print $1}')"
printf '%s  %s\n' "$hash" "$archive" > "$fake/SHA256SUMS"
for version in v9.9.9 ""; do
  out="$(DLLB_VERSION="$version" DLLB_REQUIRED=1 MOCK_CURL_MODE=release \
    DLLB_INSTALL_DIR="$WORK_DIR/success" "$INSTALLER" 2>&1)"
  status=$?
  if [ "$status" -eq 0 ] && [ -x "$WORK_DIR/success/dllb-server" ]; then
    pass "verified dllb installs with version '${version:-latest}'"
  else
    fail "verified dllb install failed: $out"
  fi
done

echo "Test 8: yoke installer verifies pinned and latest releases"
printf '#!/bin/sh\nexit 0\n' > "$fake/yoke"
hash="$(sha256sum "$fake/yoke" | awk '{print $1}')"
printf '%s  yoke\n' "$hash" > "$fake/yoke.sha256"
for version in v9.9.9 ""; do
  out="$(YOKE_VERSION="$version" MOCK_CURL_MODE=release \
    YOKE_INSTALL_DIR="$WORK_DIR/yoke-success" "$PROJECT_ROOT/scripts/install.sh" 2>&1)"
  status=$?
  if [ "$status" -eq 0 ] && [ -x "$WORK_DIR/yoke-success/yoke" ]; then
    pass "verified yoke installs with version '${version:-latest}'"
  else
    fail "verified yoke install failed: $out"
  fi
done

echo "Test 9: yoke rejects invalid checksums and failed latest lookups"
printf '%064d  yoke\n' 0 > "$fake/yoke.sha256"
out="$(YOKE_VERSION=v9.9.9 MOCK_CURL_MODE=release \
  YOKE_INSTALL_DIR="$WORK_DIR/yoke-bad" "$PROJECT_ROOT/scripts/install.sh" 2>&1)"
status=$?
if [ "$status" -eq 1 ] && [[ "$out" == *"checksum mismatch"* ]] &&
   [ ! -f "$WORK_DIR/yoke-bad/yoke" ]; then
  pass "yoke refuses a checksum mismatch"
else
  fail "yoke checksum rejection failed"
fi
out="$(YOKE_VERSION='' MOCK_CURL_MODE=fail \
  YOKE_INSTALL_DIR="$WORK_DIR/yoke-bad" "$PROJECT_ROOT/scripts/install.sh" 2>&1)"
status=$?
if [ "$status" -eq 1 ] && [[ "$out" == *"could not resolve the latest release"* ]]; then
  pass "yoke reports latest lookup failures"
else
  fail "yoke latest lookup failure was not reported"
fi

echo "Test 10: every download requests bounded retries and timeouts"
if [ -s "$MOCK_CURL_LOG" ] &&
   ! grep -v -- '--retry 3 --retry-delay 2 --retry-max-time 90 --connect-timeout 10 --max-time 30' "$MOCK_CURL_LOG"; then
  pass "all requests include retry and timeout options"
else
  fail "a download omitted bounded retry options"
fi

echo
if [ "$failures" -eq 0 ]; then
  echo "All release installer tests passed."
  exit 0
else
  echo "❌ ${failures} dllb install test(s) failed."
  exit 1
fi
