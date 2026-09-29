#!/bin/bash
# TomlBeef's own read and write paths on one input, inputs/typed.toml (the only generated input the
# typed [TomlObject] paths can bind): the document with no metadata, with source positions and with
# PreserveStyle, the typed reads, and the matching writes, including a typed update of a PreserveStyle
# document in place. Gives the other charts context: what each mode costs relative to the plain parse.
# Times are ms per operation; each cell is the median of REPEATS processes (default 3) under the rule in
# run.sh. Prints a Markdown table (save as modes-results.md for plot.py).
# Usage: modes.sh [min-samples]   (after ./build.sh tomlbeef beef && ./gen-inputs.py)
set -uo pipefail
C="$(cd "$(dirname "$0")" && pwd)"
N="${1:-5}"
REPEATS="${REPEATS:-3}"
IN="$C/inputs/typed.toml"
TT="$C/../../build/Release_Linux64/TomlTester/TomlTester"
BEEF="$C/beef/build/Release_Linux64/BeefTomlBench/BeefTomlBench"

# Median over REPEATS runs of the ms figure on the first line matching `pattern` in a command's output
median() { # pattern command...
	local pattern="$1" values=() out
	shift
	for ((r = 0; r < REPEATS; r++)); do
		out=$("$@" < "$IN" 2>&1) || { echo FAIL; return; }
		values+=("$(grep -E "$pattern" <<< "$out" | head -1 | grep -oE '[0-9.]+ ms/op' | awk '{print $1}')")
	done
	printf '%s\n' "${values[@]}" | sort -g | awk '{a[NR] = $1} END {print (NR % 2) ? a[(NR + 1) / 2] : (a[NR / 2] + a[NR / 2 + 1]) / 2}'
}

row() { # operation mode ms
	echo "| $1 | $2 | $3 |"
}

echo "input: typed.toml, $(stat -c %s "$IN") bytes"
echo
echo "| operation | mode | ms |"
echo "|---|---|---:|"
row read "Document" "$(median 'Read\(string\)' "$TT" -bench "$N")"
row read "Document + positions" "$(median 'Read\(string\)' "$TT" -bench "$N" -positions)"
row read "Document + PreserveStyle" "$(median 'Read\(string\)' "$TT" -bench "$N" -preserve)"
row read "Typed" "$(median 'ms/op' "$BEEF" typed read-plain "$IN" "$N")"
row read "Typed + positions" "$(median 'ms/op' "$BEEF" typed read "$IN" "$N")"
row read "Typed + positions, arena" "$(median 'ms/op' "$BEEF" typed read-arena "$IN" "$N")"
row write "Document" "$(median '^  Write' "$TT" -bench "$N")"
row write "Document + PreserveStyle" "$(median '^  Write' "$TT" -bench "$N" -preserve)"
row write "Typed" "$(median 'ms/op' "$BEEF" typed write "$IN" "$N")"
row write "Typed update + PreserveStyle" "$(median 'ms/op' "$BEEF" typed write-preserve "$IN" "$N")"
