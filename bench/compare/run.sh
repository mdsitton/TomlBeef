#!/bin/bash
# Runs every parser on every input and prints a Markdown table of MB/s. Each cell is one process:
# read the file, parse once to warm up, then average up to N parses within a 3 s budget (TomlBeef:
# N parses through `TomlTester -bench`, its Read(string) figure). FAIL means the parser rejected the
# input; TIMEOUT means it ran past LIMIT seconds (default 60). Setup: ./fetch.sh && ./build.sh && ./gen-inputs.py
# Usage: run.sh [iterations] [input names...]
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
# every cell has a time limit. A cell that runs out prints TIMEOUT: unlike FAIL, the input was not
# rejected, and plot.py counts it at its best possible speed (input size / LIMIT).
LIMIT="${LIMIT:-60}"

# Runs a harness under the limit and prints its MB/s, TIMEOUT, or nothing (a failure)
cell() {
	local out
	out=$(timeout "$LIMIT" "$@" 2>&1)
	if [ $? -eq 124 ]; then echo TIMEOUT; return; fi
	echo "$out" | grep -oE '[0-9.]+ MB/s' | head -1 | awk '{print $1}'
}

# TomlBeef's own -bench prints several read paths; take Read(string)
tomlbeef() {
	local out
	out=$(timeout "$LIMIT" "$TB" -bench "$N" "${@:2}" < "$1" 2>&1)
	if [ $? -eq 124 ]; then echo TIMEOUT; return; fi
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
		v=$(run "$p" "$f")
		line+=" ${v:-FAIL} |"
	done
	echo "$line"
done
