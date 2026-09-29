#!/bin/bash
# TomlBeef against Beef's built-in TOML reader (Beefy.utils.StructuredData, used by the IDE and
# BeefBuild for project files), both built into beef/ by the same compiler. StructuredData is not a
# TOML parser in the spec sense (no dotted keys, literal or multi-line strings, dates are kept as
# text, floats are float32, almost no validation), so this compares only where both produce the same
# values; `check` verifies that. Prints Markdown tables. Timings follow the rule in run.sh; each cell
# is the median of REPEATS processes (default 3).
# Usage: beef.sh [min-samples]   (after ./fetch.sh && ./build.sh beef && ./gen-inputs.py)
set -uo pipefail
C="$(cd "$(dirname "$0")" && pwd)"
BB="$C/beef/build/Release_Linux64/BeefTomlBench/BeefTomlBench"
TESTS="$C/../../tests"
N="${1:-5}"
REPEATS="${REPEATS:-3}"

# Median of REPEATS runs of a command's first "<number> <unit>" figure
median() { # unit command...
	local unit="$1" values=() out
	shift
	for ((r = 0; r < REPEATS; r++)); do
		out=$("$@" 2>&1) || { echo FAIL; return; }
		values+=("$(echo "$out" | grep -oE "[0-9.]+ $unit" | head -1 | awk '{print $1}')")
	done
	printf '%s\n' "${values[@]}" | sort -g | awk '{a[NR] = $1} END {print (NR % 2) ? a[(NR + 1) / 2] : (a[NR / 2] + a[NR / 2 + 1]) / 2}'
}

echo "### Values: does StructuredData read the same data?"
echo
echo '```'
for f in mixed commented comments strings ints floats dates arrays headers dotted; do
	"$BB" check "$C/inputs/$f.toml" | head -1
done
echo "beef-projects: $("$BB" check "$C/inputs/beef-projects" | tail -1)"
echo "toml-test valid: $("$BB" check "$TESTS/valid" | tail -1)"
echo "toml-test invalid: $("$BB" check "$TESTS/invalid" | tail -1)"
echo '```'
echo

echo "### Parsing (MB/s, higher is better)"
echo
echo "| input | StructuredData | TomlBeef | TomlBeef preserve | like-for-like |"
echo "|---|---:|---:|---:|---|"
row() { # name label paths...
	local name="$1" note="$2"
	shift 2
	echo "| $name | $(median MB/s "$BB" parse structured "$N" "$@") | $(median MB/s "$BB" parse tomlbeef "$N" "$@") | $(median MB/s "$BB" parse tomlbeef-preserve "$N" "$@") | $note |"
}
row "Beef project files" "yes (both read the same values; files either rejects are skipped)" "$C/inputs/beef-projects"
for f in commented comments strings ints arrays headers; do
	row "$f" "yes" "$C/inputs/$f.toml"
done
row floats "no: StructuredData parses float32" "$C/inputs/floats.toml"
row dates "no: StructuredData keeps dates as text" "$C/inputs/dates.toml"
echo
echo "mixed and dotted: StructuredData cannot read them (literal strings, dotted keys)."
echo

echo "### Key lookups (ns per lookup, lower is better)"
echo
echo "| document | StructuredData (Open + TryGet) | TomlBeef |"
echo "|---|---:|---:|"
echo "| 200 tables × 1000 keys | $(median ns/lookup "$BB" lookup structured "$C/inputs/ints.toml" "$C/inputs/ints.lookups" "$N") | $(median ns/lookup "$BB" lookup tomlbeef "$C/inputs/ints.toml" "$C/inputs/ints.lookups" "$N") |"
echo

echo "### Writing (MB/s of output, higher is better)"
echo
echo "| input | StructuredData ToTOML | TomlBeef Write |"
echo "|---|---:|---:|"
for f in commented strings ints arrays headers; do
	echo "| $f | $(median MB/s "$BB" write structured "$N" "$C/inputs/$f.toml") | $(median MB/s "$BB" write tomlbeef "$N" "$C/inputs/$f.toml") |"
done
