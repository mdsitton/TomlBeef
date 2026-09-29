#!/bin/bash
# Runs every parser on every input and prints a Markdown table of MB/s. Each cell is one process:
# read the file, parse once to warm up, then average up to N parses within a 3 s budget (TomlBeef:
# N parses through `TomlTester -bench`, its Read(string) figure). FAIL means the parser rejected the
# input. Setup: ./fetch.sh && ./build.sh && ./gen-inputs.py
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

mbps() { grep -oE '[0-9.]+ MB/s' | head -1 | awk '{print $1}'; }

run() { # parser file
	case "$1" in
		TomlBeef)           "$TB" -bench "$N" < "$2" 2>&1 | grep 'Read(string)' | awk '{print $4}' ;;
		TomlBeef\ preserve) "$TB" -bench "$N" -preserve < "$2" 2>&1 | grep 'Read(string)' | awk '{print $4}' ;;
		tomlc17)            "$B/tomlc17" "$2" "$N" 2>&1 | mbps ;;
		toml-c)             "$B/toml-c" "$2" "$N" 2>&1 | mbps ;;
		toml11)             "$B/toml11" "$2" "$N" 2>&1 | mbps ;;
		toml++)             "$B/tomlplusplus" "$2" "$N" 2>&1 | mbps ;;
		glaze)              "$B/glaze" "$2" "$N" 2>&1 | mbps ;;
		toml\ \(Rust\))     "$B/rust-tomlbench" toml "$2" "$N" 2>&1 | mbps ;;
		toml_edit)          "$B/rust-tomlbench" edit "$2" "$N" 2>&1 | mbps ;;
		BurntSushi)         "$B/go-tomlbench" burntsushi "$2" "$N" 2>&1 | mbps ;;
		go-toml)            "$B/go-tomlbench" gotoml "$2" "$N" 2>&1 | mbps ;;
		Tomlyn)             "$B/tomlyn/TomlynBench" model "$2" "$N" 2>&1 | mbps ;;
		Tomlyn\ syntax)     "$B/tomlyn/TomlynBench" syntax "$2" "$N" 2>&1 | mbps ;;
	esac
}

# Data-model parsers, then the style-preserving ones
parsers=("TomlBeef" "tomlc17" "toml-c" "toml11" "toml++" "glaze" "toml (Rust)" "BurntSushi" "go-toml" "Tomlyn"
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
