#!/bin/bash
# Roundtrip test: parse TOML → write TOML → re-parse → compare tagged JSON
# Usage: ./test-roundtrip.sh [path_to_valid_toml-tests]
#
# Outputs a summary to stdout and detailed failure info to test-roundtrip.log
#
# Roundtrip JSON is compared semantically with json-compare.py so TOML object
# ordering changes do not count as failures. Real value/type/shape changes do.

shopt -s globstar nullglob

BIN="${BIN:-./build/Debug_Linux64/TomlTester/TomlTester}"
TESTDIR="${1:-toml-test/tests/valid}"
# Normalize: strip leading ./ and trailing / for stable log output.
TESTDIR="${TESTDIR#./}"
TESTDIR="${TESTDIR%/}"
LOGFILE="test-roundtrip.log"
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
parse_fail=0
encode_fail=0
reparse_fail=0
crash=0

# Truncate log
{
	echo "=== Roundtrip Test Log ==="
	echo "Date: $(date)"
	echo "Binary: $BIN"
	echo "Test dir: $TESTDIR"
	echo "Comparator: $COMPARE"
	echo ""
} > "$LOGFILE"

for f in "$TESTDIR"/**/*.toml; do
	# Parse original → tagged JSON, capture stderr
	json1=$(("$BIN" < "$f") 2>&1) || {
		{
			echo "--- PARSE FAIL: $f ---"
			echo "Exit: $?"
			echo "Stderr: $json1"
			echo ""
		} >> "$LOGFILE"
		parse_fail=$((parse_fail + 1))
		continue
	}

	# Parse original → write TOML, capture stderr
	toml=$(("$BIN" -encode < "$f") 2>&1) || {
		{
			echo "--- ENCODE FAIL: $f ---"
			echo "Exit: $?"
			echo "Stderr: $toml"
			echo ""
		} >> "$LOGFILE"
		encode_fail=$((encode_fail + 1))
		continue
	}

	# Re-parse written TOML → tagged JSON, capture stderr
	json2=$(echo "$toml" | "$BIN" 2>&1) || {
		rc=$?
		{
			echo "--- REPARSE FAIL: $f ---"
			echo "Exit: $rc"
			echo "Written TOML:"
			echo "$toml"
			echo "Stderr: $json2"
			echo ""
		} >> "$LOGFILE"
		if [ $rc -eq 139 ]; then crash=$((crash + 1)); fi
		reparse_fail=$((reparse_fail + 1))
		continue
	}

	# Compare semantically. json-compare.py expects the expected JSON in a file
	# and the actual JSON on stdin.
	expected_tmp=$(mktemp) || {
		{
			echo "--- COMPARE SETUP FAIL: $f ---"
			echo "mktemp failed"
			echo ""
		} >> "$LOGFILE"
		compare_fail=$((compare_fail + 1))
		continue
	}
	printf '%s' "$json1" > "$expected_tmp"
	compare_output=$(printf '%s' "$json2" | "$COMPARE" "$expected_tmp" 2>&1)
	compare_rc=$?
	rm -f "$expected_tmp"

	if [ $compare_rc -ne 0 ]; then
		if [ $compare_rc -eq 1 ]; then
			semantic_mismatch=$((semantic_mismatch + 1))
		else
			compare_fail=$((compare_fail + 1))
		fi
		{
			echo "--- SEMANTIC MISMATCH: $f ---"
			echo "Comparator exit: $compare_rc"
			echo ""
			echo "--- Comparator output ---"
			echo "$compare_output"
			echo ""
			echo "--- Original JSON ---"
			echo "$json1"
			echo ""
			echo "--- Roundtrip JSON ---"
			echo "$json2"
			echo ""
		} >> "$LOGFILE"
	else
		pass=$((pass + 1))
	fi
done

{
	echo "=== Summary ==="
	echo "Pass:                $pass"
	echo "Semantic mismatch:   $semantic_mismatch"
	echo "Compare fail:        $compare_fail"
	echo "Parse fail:          $parse_fail"
	echo "Encode fail:         $encode_fail"
	echo "Reparse fail:        $reparse_fail"
	echo "Crash:               $crash"
} | tee -a "$LOGFILE"

if [ "$crash" -gt 0 ] || [ "$parse_fail" -gt 0 ] || [ "$encode_fail" -gt 0 ] || [ "$reparse_fail" -gt 0 ] || [ "$semantic_mismatch" -gt 0 ] || [ "$compare_fail" -gt 0 ]; then
	exit 1
fi
exit 0
