#!/bin/bash
# Run the official upstream toml-test decoder suite against TomlTester.
#
# This intentionally uses the upstream Go module instead of the vendored/root
# toml-test/ checkout, so the local toml-test directory is not required.
#
# Environment overrides:
#   BIN              Decoder binary to test.
#   TOML_TEST_PKG    Go module for the official runner.
#   TOML_TEST_BIN    Existing toml-test binary to use instead of `go run`.
#   LOGDIR           Directory for per-version logs.

set -u

BIN="${BIN:-./build/Debug_Linux64/TomlTester/TomlTester}"
TOML_TEST_PKG="${TOML_TEST_PKG:-github.com/toml-lang/toml-test/v2/cmd/toml-test@v2.2.0}"
LOGDIR="${LOGDIR:-.}"

if [ ! -x "$BIN" ]; then
	echo "ERROR: $BIN not found or not executable. Build first with: beefbuild"
	exit 1
fi

if [ -z "${TOML_TEST_BIN:-}" ] && ! command -v go >/dev/null 2>&1; then
	echo "ERROR: go is required when TOML_TEST_BIN is not set."
	exit 1
fi

mkdir -p "$LOGDIR" || exit 1

run_version() {
	local version="$1"
	local logfile="$LOGDIR/test-official-toml-${version}.log"
	local decoder="$BIN -toml $version"
	local rc

	echo "=== Official toml-test ${version} ==="
	echo "Decoder: $decoder"
	if [ -n "${TOML_TEST_BIN:-}" ]; then
		echo "Runner:  $TOML_TEST_BIN"
		"$TOML_TEST_BIN" test -decoder="$decoder" -toml="$version" -color=never > "$logfile" 2>&1
		rc=$?
	else
		echo "Runner:  go run $TOML_TEST_PKG"
		go run "$TOML_TEST_PKG" test -decoder="$decoder" -toml="$version" -color=never > "$logfile" 2>&1
		rc=$?
	fi

	cat "$logfile"
	echo "official_toml_test_${version}_exit=$rc"
	echo
	return $rc
}

overall=0
run_version "1.0" || overall=1
run_version "1.1" || overall=1

exit $overall
