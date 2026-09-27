#!/bin/bash
# Encoder test: tagged JSON fixture → TomlTester -from-json → TOML → TomlTester → tagged JSON,
# compared semantically against the original fixture JSON.
# Usage: ./test-encoder.sh [path_to_valid_tests] (default: tests/valid)
#
# Outputs a summary to stdout and detailed failure info to test-encoder.log.
# This is the local counterpart of the upstream toml-test encoder suite
# (see test-official-toml.sh).

shopt -s globstar nullglob

BIN="${BIN:-./build/Debug_Linux64/TomlTester/TomlTester}"
TESTDIR="${1:-tests/valid}"
TESTDIR="${TESTDIR#./}"
TESTDIR="${TESTDIR%/}"
LOGFILE="test-encoder.log"
COMPARE="${COMPARE:-./json-compare.py}"

if [ ! -x "$BIN" ]; then
	echo "ERROR: $BIN not found or not executable. Build first with: beefbuild"
	exit 1
fi

if [ ! -x "$COMPARE" ]; then
	echo "ERROR: $COMPARE not found or not executable."
	exit 1
fi

pass=0
semantic_mismatch=0
compare_fail=0
encode_fail=0
reparse_fail=0
crash=0

{
	echo "=== Encoder Test Log ==="
	echo "Date: $(date)"
	echo "Binary: $BIN"
	echo "Test dir: $TESTDIR"
	echo "Comparator: $COMPARE"
	echo ""
} > "$LOGFILE"

for f in "$TESTDIR"/**/*.json; do
	# Fixture JSON → TOML
	toml=$(("$BIN" -from-json < "$f") 2>&1)
	rc=$?
	if [ $rc -ne 0 ]; then
		{
			echo "--- ENCODE FAIL: $f ---"
			echo "Exit: $rc"
			echo "Output: $toml"
			echo ""
		} >> "$LOGFILE"
		if [ $rc -ge 128 ]; then crash=$((crash + 1)); fi
		encode_fail=$((encode_fail + 1))
		continue
	fi

	# Written TOML → tagged JSON
	json=$(printf '%s' "$toml" | "$BIN" 2>&1)
	rc=$?
	if [ $rc -ne 0 ]; then
		{
			echo "--- REPARSE FAIL: $f ---"
			echo "Exit: $rc"
			echo "Written TOML:"
			echo "$toml"
			echo "Stderr: $json"
			echo ""
		} >> "$LOGFILE"
		if [ $rc -ge 128 ]; then crash=$((crash + 1)); fi
		reparse_fail=$((reparse_fail + 1))
		continue
	fi

	# json-compare.py takes the expected JSON as a file and the actual JSON on stdin
	compare_output=$(printf '%s' "$json" | "$COMPARE" "$f" 2>&1)
	compare_rc=$?
	if [ $compare_rc -eq 0 ]; then
		pass=$((pass + 1))
		continue
	fi

	if [ $compare_rc -eq 1 ]; then
		semantic_mismatch=$((semantic_mismatch + 1))
	else
		compare_fail=$((compare_fail + 1))
	fi
	{
		echo "--- SEMANTIC MISMATCH: $f ---"
		echo "Comparator exit: $compare_rc"
		echo "$compare_output"
		echo ""
		echo "--- Written TOML ---"
		echo "$toml"
		echo ""
	} >> "$LOGFILE"
done

{
	echo "=== Summary ==="
	echo "Pass:                $pass"
	echo "Semantic mismatch:   $semantic_mismatch"
	echo "Compare fail:        $compare_fail"
	echo "Encode fail:         $encode_fail"
	echo "Reparse fail:        $reparse_fail"
	echo "Crash:               $crash"
} | tee -a "$LOGFILE"

if [ "$crash" -gt 0 ] || [ "$encode_fail" -gt 0 ] || [ "$reparse_fail" -gt 0 ] || [ "$semantic_mismatch" -gt 0 ] || [ "$compare_fail" -gt 0 ]; then
	exit 1
fi
exit 0
