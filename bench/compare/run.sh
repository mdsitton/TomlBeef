#!/bin/bash
# Runs every parser on every input and prints a Markdown table of MB/s (TomlBeef: `TomlTester -bench`,
# its Read(string) figure).
#
# Measurement rule, shared by every harness (c/bench.h, rust, zig, go, java, cs, js, TomlTester):
#   1. Warm up: run the operation for at least 1 s (at least once), for native code and JITs alike.
#   2. Sample: time single operations until at least N samples (default 5) were taken and at least
#      60% of them lie within ±10% of their median ("converged"), or 10 s of measuring or 1000
#      samples have passed ("capped"). Report the median sample.
#   3. Repeat: run each cell REPEATS times (default 3) in fresh processes and take the median, since
#      memory layout, hash seeds and CPU clocks differ between processes.
# FAIL means the parser rejected the input; DNF means a run did not finish within LIMIT seconds
# (default 60). Setup: ./fetch.sh && ./build.sh && ./gen-inputs.py
# Usage: run.sh [min-samples] [input names...]
# Save the table as results.md and run plot.py to redraw docs/benchmark.svg.
set -uo pipefail
C="$(cd "$(dirname "$0")" && pwd)"
B="$C/bin"
TB="$C/../../build/Release_Linux64/TomlTester/TomlTester"
N="${1:-5}"
shift || true

if [ $# -gt 0 ]; then
	inputs=("$@")
else
	inputs=(mixed commented comments strings ints floats dates arrays headers dotted)
fi

# Some parsers take minutes per parse on some inputs (superlinear in table count or input size), so
# every cell has a time limit. A cell that runs out prints DNF (did not finish): unlike FAIL, the input was not
# rejected, and plot.py counts it at its best possible speed (input size / LIMIT).
LIMIT="${LIMIT:-60}"

# Runs a harness under the limit and prints its MB/s, DNF, or nothing (a failure)
cell() {
	local out
	out=$(timeout "$LIMIT" "$@" 2>&1)
	if [ $? -eq 124 ]; then echo DNF; return; fi
	echo "$out" | grep -oE '[0-9.]+ MB/s' | head -1 | awk '{print $1}'
}

# TomlBeef's own -bench prints several read paths; take Read(string)
tomlbeef() {
	local out
	out=$(timeout "$LIMIT" "$TB" -bench "$N" "${@:2}" < "$1" 2>&1)
	if [ $? -eq 124 ]; then echo DNF; return; fi
	echo "$out" | grep 'Read(string)' | awk '{print $4}'
}

run() { # parser file
	case "$1" in
		TomlBeef)           tomlbeef "$2" ;;
		TomlBeef\ preserve) tomlbeef "$2" -preserve ;;
		tomlc17)            cell "$B/tomlc17" "$2" "$N" ;;
		toml-c)             cell "$B/toml-c" "$2" "$N" ;;
		toml11)             cell "$B/toml11" "$2" "$N" ;;
		toml++)             cell "$B/tomlplusplus" "$2" "$N" ;;
		glaze)              cell "$B/glaze" "$2" "$N" ;;
		toml\ \(Rust\))     cell "$B/rust-tomlbench" toml "$2" "$N" ;;
		toml-spanner)       cell "$B/rust-tomlbench" spanner "$2" "$N" ;;
		toml-span)          cell "$B/rust-tomlbench" span "$2" "$N" ;;
		toml_edit)          cell "$B/rust-tomlbench" edit "$2" "$N" ;;
		zig-toml)           cell "$B/zig-toml" "$2" "$N" ;;
		BurntSushi)         cell "$B/go-tomlbench" burntsushi "$2" "$N" ;;
		go-toml)            cell "$B/go-tomlbench" gotoml "$2" "$N" ;;
		tomlj)              cell "$B/java/bin/tomlbench" tomlj "$2" "$N" ;;
		jtoml)              cell "$B/java/bin/tomlbench" jtoml "$2" "$N" ;;
		Tomlyn)             cell "$B/tomlyn/TomlynBench" model "$2" "$N" ;;
		Tomlyn\ syntax)     cell "$B/tomlyn/TomlynBench" syntax "$2" "$N" ;;
		js-toml)            cell node "$C/js/bench.mjs" js-toml "$2" "$N" ;;
		smol-toml)          cell node "$C/js/bench.mjs" smol-toml "$2" "$N" ;;
		toml\ \(JS\))       cell node "$C/js/bench.mjs" toml "$2" "$N" ;;
	esac
}

# Runs a cell REPEATS times, each in a fresh process (layout, hash seeds and CPU clocks differ between
# processes), and prints the median; DNF as soon as one run does not finish, nothing if the parser fails
REPEATS="${REPEATS:-3}"
repeated() { # parser file
	local values=() v
	for ((r = 0; r < REPEATS; r++)); do
		v=$(run "$1" "$2")
		if [ "$v" = DNF ]; then echo DNF; return; fi
		if [ -z "$v" ]; then return; fi
		values+=("$v")
	done
	printf '%s\n' "${values[@]}" | sort -g | awk '{a[NR] = $1} END {print (NR % 2) ? a[(NR + 1) / 2] : (a[NR / 2] + a[NR / 2 + 1]) / 2}'
}

# Data-model parsers, then the style-preserving ones
parsers=("TomlBeef" "tomlc17" "toml-c" "toml11" "toml++" "glaze" "toml (Rust)" "toml-spanner" "toml-span"
	"zig-toml" "BurntSushi" "go-toml" "tomlj" "jtoml" "Tomlyn" "js-toml" "smol-toml" "toml (JS)"
	"TomlBeef preserve" "toml_edit" "Tomlyn syntax")

header="| input |"
rule="|---|"
for p in "${parsers[@]}"; do header+=" $p |"; rule+="---:|"; done
echo "$header"
echo "$rule"
for name in "${inputs[@]}"; do
	f="$C/inputs/$name.toml"
	line="| $name |"
	for p in "${parsers[@]}"; do
		v=$(repeated "$p" "$f")
		line+=" ${v:-FAIL} |"
	done
	echo "$line"
done
