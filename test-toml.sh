#!/bin/bash
# TOML test: parse valid/invalid files against toml-test expectations,
# with semantic comparison of valid fixture outputs against expected JSON.
# Usage: ./test-toml.sh [path_to_toml-test]
#
# Version selection:
#   Valid tests:        always run with default (v1.1)
#   Invalid tests:      spec-1.1.0/ → v1.1
#                       everything else → v1.0 (toml-test default)

shopt -s globstar nullglob

BIN="${BIN:-./build/Debug_Linux64/TomlTester/TomlTester}"
TESTDIR="${1:-toml-test/tests}"
LOGFILE="${LOGFILE:-test-toml-mismatches.log}"
COMPARE="${COMPARE:-./json-compare.py}"

if [ ! -x "$BIN" ]; then
	echo "ERROR: $BIN not found or not executable. Build first with: beefbuild"
	exit 1
fi

if ! command -v python3 &> /dev/null; then
	echo "ERROR: python3 is required for semantic fixture comparison."
	exit 1
fi

if [ ! -f "$COMPARE" ]; then
	echo "ERROR: $COMPARE not found."
	exit 1
fi

invalid_version_flag() {
	local path="$1"
	if [[ "$path" == *"/spec-1.1.0/"* ]]; then
		echo "-toml 1.1"
	else
		echo "-toml 1.0"
	fi
}

# Counters
vp=0 vf=0          # valid: parse pass / parse fail
vs=0 vmissing=0 vsm=0   # valid: semantic pass / missing expected JSON / semantic mismatch
ir=0 ia=0 ise=0    # invalid: rejected / accepted / segfault
total_mismatches=0

>"$LOGFILE"  # truncate

echo "=== Valid tests ==="
for f in "$TESTDIR"/valid/**/*.toml; do
	expected="${f%.toml}.json"

	# Parse-only check
	output="$("$BIN" < "$f" 2>/dev/null)"
	rc=$?
	if [ $rc -ne 0 ]; then
		echo "  PARSE FAIL: $f"
		vf=$((vf + 1))
		continue
	fi
	vp=$((vp + 1))

	# Semantic check: decode output must match expected JSON
	if [ ! -f "$expected" ]; then
		echo "  NO EXPECTED JSON: $f"
		vmissing=$((vmissing + 1))
		continue
	fi

	if echo "$output" | python3 "$COMPARE" "$expected" > /dev/null 2>&1; then
		vs=$((vs + 1))
	else
		echo "  MISMATCH: $f"
		total_mismatches=$((total_mismatches + 1))
		vsm=$((vsm + 1))
		{
			echo "=== MISMATCH: $f ==="
			echo "$output" | python3 "$COMPARE" "$expected" 2>&1
			echo ""
		} >> "$LOGFILE"
	fi
done

echo ""
echo "=== Invalid tests ==="
for f in "$TESTDIR"/invalid/**/*.toml; do
	vflag=$(invalid_version_flag "$f")
	"$BIN" $vflag < "$f" > /dev/null 2>&1
	rc=$?
	if [ $rc -eq 139 ]; then
		echo "  SEGFAULT: $f"
		ise=$((ise + 1))
		ia=$((ia + 1))
	elif [ $rc -eq 0 ]; then
		echo "  ACCEPT (should reject): $f"
		ia=$((ia + 1))
	else
		ir=$((ir + 1))
	fi
done

echo ""
echo "=== Results ==="
echo "Valid parse:     $vp pass, $vf fail"
echo "Valid semantic:  $vs pass, $vmissing missing json, $vsm mismatch"
echo "Invalid:         $ir rejected, $ia accepted ($ise segfaults)"

if [ $total_mismatches -gt 0 ]; then
	echo ""
	echo "Mismatch details written to: $LOGFILE"
fi

if [ "$vf" -gt 0 ] || [ "$ia" -gt 0 ] || [ "$vmissing" -gt 0 ] || [ $total_mismatches -gt 0 ]; then
	exit 1
fi
