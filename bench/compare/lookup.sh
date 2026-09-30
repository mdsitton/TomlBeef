#!/bin/bash
# Key lookups after parsing: each library parses a document once (untimed), then times 100000 random
# `table key` lookups (inputs/<name>.lookups, written by gen-inputs.py), each reading an integer
# through the library's own table API. Prints a Markdown table of ns per lookup (rows: documents;
# columns: libraries, named as in results.md). FAIL means the library could not parse the document;
# DNF means a run (parse included) did not finish within LIMIT seconds. One sample is a pass over all
# 100000 lookups, measured under the rule in run.sh; each cell is the median of REPEATS runs in fresh
# processes (default 3). Every run that finished must report the same sum of values found, which the
# script checks.
# Usage: lookup.sh [min-samples]   (after ./build.sh && ./gen-inputs.py)
# With ONLY (merge.sh), for example ONLY='TomlBeef.*' ./lookup.sh, only the matching libraries are
# measured (their sums checked against each other) and lookup-results.md is updated in place.
set -uo pipefail
C="$(cd "$(dirname "$0")" && pwd)"
B="$C/bin"
TB="$C/../../build/Release_Linux64/TomlTester/TomlTester"
source "$C/merge.sh"
merge_into "$C/lookup-results.md" "$@"
N="${1:-5}"
LIMIT="${LIMIT:-60}"
REPEATS="${REPEATS:-3}"

libs=("TomlBeef" "tomlc17" "toml-c" "toml11" "toml++" "glaze" "toml (Rust)" "toml-spanner" "toml-span"
	"zig-toml" "BurntSushi" "go-toml" "tomlj" "jtoml" "Tomlyn" "js-toml" "smol-toml" "toml (JS)"
	"TomlBeef preserve" "toml_edit" "Tomlyn syntax")
declare -A shape=(["ints"]="200 tables × 1000 keys" ["mixed"]="15000 root sections × ~10 keys")

run() { # library toml lookups
	case "$1" in
		TomlBeef)           "$TB" -lookup "$3" -bench "$N" < "$2" ;;
		TomlBeef\ preserve) "$TB" -lookup "$3" -bench "$N" -preserve < "$2" ;;
		tomlc17)            "$B/tomlc17" "$2" "$N" "$3" ;;
		toml-c)             "$B/toml-c" "$2" "$N" "$3" ;;
		toml11)             "$B/toml11" "$2" "$N" "$3" ;;
		toml++)             "$B/tomlplusplus" "$2" "$N" "$3" ;;
		glaze)              "$B/glaze" "$2" "$N" "$3" ;;
		toml\ \(Rust\))     "$B/rust-tomlbench" lookup toml "$2" "$3" "$N" ;;
		toml_edit)          "$B/rust-tomlbench" lookup edit "$2" "$3" "$N" ;;
		toml-spanner)       "$B/rust-tomlbench" lookup spanner "$2" "$3" "$N" ;;
		toml-span)          "$B/rust-tomlbench" lookup span "$2" "$3" "$N" ;;
		zig-toml)           "$B/zig-toml" "$2" "$N" "$3" ;;
		BurntSushi)         "$B/go-tomlbench" lookup burntsushi "$2" "$3" "$N" ;;
		go-toml)            "$B/go-tomlbench" lookup gotoml "$2" "$3" "$N" ;;
		tomlj)              "$B/java/bin/tomlbench" lookup tomlj "$2" "$3" "$N" ;;
		jtoml)              "$B/java/bin/tomlbench" lookup jtoml "$2" "$3" "$N" ;;
		Tomlyn)             "$B/tomlyn/TomlynBench" lookup model "$2" "$3" "$N" ;;
		Tomlyn\ syntax)     "$B/tomlyn/TomlynBench" lookup syntax "$2" "$3" "$N" ;;
		js-toml)            node "$C/js/bench.mjs" lookup js-toml "$2" "$3" "$N" ;;
		smol-toml)          node "$C/js/bench.mjs" lookup smol-toml "$2" "$3" "$N" ;;
		toml\ \(JS\))       node "$C/js/bench.mjs" lookup toml "$2" "$3" "$N" ;;
	esac
}
export -f run
export TB B C N

header="| document |"; rule="|---|"
for l in "${libs[@]}"; do header+=" $l |"; rule+="---:|"; done
echo "$header"; echo "$rule"
status=0
for name in ints mixed; do
	line="| ${shape[$name]} |"
	sums=()
	for l in "${libs[@]}"; do
		if ! selected "$l"; then
			line+=" $(saved_cell "${shape[$name]}" "$l") |"
			continue
		fi
		# REPEATS runs in fresh processes, median reported; DNF or FAIL as soon as one run is
		values=()
		cell=""
		for ((r = 0; r < REPEATS; r++)); do
			out=$(timeout "$LIMIT" bash -c 'run "$@"' _ "$l" "$C/inputs/$name.toml" "$C/inputs/$name.lookups" 2>&1)
			code=$?
			ns=$(echo "$out" | grep -oE '^[0-9.]+ ns/lookup' | awk '{print $1}')
			if [ $code -eq 124 ]; then cell=DNF; break; fi
			if [ -z "$ns" ]; then cell=FAIL; break; fi
			values+=("$ns")
			sums+=("$(echo "$out" | grep -oE 'sum [0-9]+, missing [0-9]+')")
		done
		if [ -z "$cell" ]; then
			cell=$(printf '%s\n' "${values[@]}" | sort -g | awk '{a[NR] = $1} END {print (NR % 2) ? a[(NR + 1) / 2] : (a[NR / 2] + a[NR / 2 + 1]) / 2}')
		fi
		line+=" $cell |"
	done
	echo "$line"
	# Every library that finished must have found the same values
	if [ "$(printf '%s\n' "${sums[@]}" | sort -u | wc -l)" -ne 1 ]; then
		echo "results differ for $name: $(printf '%s; ' "${sums[@]}")" >&2
		status=1
	fi
done
exit $status
