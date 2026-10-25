#!/usr/bin/env bash
# Local gate (docs/design.md section 15): Swift build + tests, check-secrets suite, secrets scan.
set -euo pipefail

if [[ "$(uname -m)" != "arm64" ]]; then
  echo "check.sh: Apple Silicon (arm64) only; got $(uname -m)" >&2
  exit 1
fi

cd "$(dirname "$0")/.."

swift build
# Keep the Swift test log outside the repo too, so a failure can be inspected after the run.
SWIFT_TEST_LOG="${TMPDIR:-/tmp}/sideload-swift-test.log"
if ! swift test 2>&1 | tee "$SWIFT_TEST_LOG"; then
  echo "check.sh: swift test failed; full output in $SWIFT_TEST_LOG" >&2
  exit 1
fi
# The DEBUG-only SIDELOAD_TEST_FORCE_SLOT hook (docs/design.md section 18) must not exist in a release build. The tests
# build debug, so this builds the release CLI and proves it twice: the variable's name is not in the binary, and with
# the variable set the binary does not answer SLOT_PENDING. The run holds the temp home's .op.lock itself, so a release
# binary stops at OPERATION_IN_PROGRESS before any keychain or device access (a debug one would answer before the lock).
swift build -c release --product sideload
RELEASE_BIN="$(swift build -c release --product sideload --show-bin-path)/sideload"
if strings -a "$RELEASE_BIN" | grep -q SIDELOAD_TEST_FORCE_SLOT; then
  echo "check.sh: the release sideload contains SIDELOAD_TEST_FORCE_SLOT" >&2
  exit 1
fi
HOOK_HOME="$(mktemp -d "${TMPDIR:-/tmp}/sideload-hook.XXXXXX")"
trap 'rm -rf "$HOOK_HOME"' EXIT
printf '%s\n' '{"devices":{"iphone":{"udid":"check-fake-id","coreDeviceId":"check-fake-core","platform":"ios"}}}' >"$HOOK_HOME/config.json"
HOOK_OUT="$(
  SIDELOAD_HOME="$HOOK_HOME" SIDELOAD_TEST_FORCE_SLOT=pending perl -MFcntl=:flock -e '
    open(my $lock, ">", "$ENV{SIDELOAD_HOME}/.op.lock") or die "lock: $!";
    flock($lock, LOCK_EX | LOCK_NB) or die "flock: $!";
    my $pid = fork() // die "fork: $!";
    if ($pid == 0) { setpgrp(0, 0); exec @ARGV or die "exec: $!"; }
    # The child leads its own process group; after 30 s the whole group is killed, so a hung probe cannot outlive the gate.
    $SIG{ALRM} = sub { kill "KILL", -$pid; kill "KILL", $pid; };
    alarm 30;
    waitpid($pid, 0);' "$RELEASE_BIN" slot return --device iphone 2>/dev/null || true
)"
if [[ "$HOOK_OUT" == *SLOT_PENDING* ]] || [[ "$HOOK_OUT" != *OPERATION_IN_PROGRESS* ]]; then
  echo "check.sh: the release sideload did not ignore SIDELOAD_TEST_FORCE_SLOT; it printed: $HOOK_OUT" >&2
  exit 1
fi
rm -rf "$HOOK_HOME"
trap - EXIT
# Keep the secrets suite output outside the repo so a flaky failure shows which test was cancelled.
TEST_LOG="${TMPDIR:-/tmp}/sideload-pnpm-test.log"
if ! pnpm test 2>&1 | tee "$TEST_LOG"; then
  echo "check.sh: pnpm test failed; full output in $TEST_LOG" >&2
  exit 1
fi
node scripts/check-secrets.mjs --all
