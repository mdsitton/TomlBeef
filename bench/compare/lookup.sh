#!/bin/bash
# Key lookups after parsing: parse a document once (untimed), then time 100000 random `table key`
# lookups (inputs/<name>.lookups, written by gen-inputs.py), each reading an integer through the
# library's own table API. Prints a Markdown table of ns per lookup; every library must report the
# same sum of values found, which the script checks. Covers TomlBeef and the Rust libraries.
# Usage: lookup.sh [passes]   (after ./build.sh tomlbeef rust && ./gen-inputs.py)
set -uo pipefail
C="$(cd "$(dirname "$0")" && pwd)"
TB="$C/../../build/Release_Linux64/TomlTester/TomlTester"
N="${1:-5}"

libs=("TomlBeef" "toml-spanner" "toml (Rust)" "toml_edit")
declare -A mode=(["toml-spanner"]=spanner ["toml (Rust)"]=toml ["toml_edit"]=edit)
declare -A shape=(["ints"]="200 tables × 1000 keys" ["mixed"]="15000 root sections × ~10 keys")

header="| document |"; rule="|---|"
for l in "${libs[@]}"; do header+=" $l |"; rule+="---:|"; done
echo "$header"; echo "$rule"
for name in ints mixed; do
	line="| ${shape[$name]} |"
	sums=()
	for l in "${libs[@]}"; do
		if [ "$l" = TomlBeef ]; then
			out=$("$TB" -lookup "$C/inputs/$name.lookups" -bench "$N" < "$C/inputs/$name.toml")
		else
			out=$("$C/bin/rust-tomlbench" lookup "${mode[$l]}" "$C/inputs/$name.toml" "$C/inputs/$name.lookups" "$N")
		fi
		line+=" $(echo "$out" | grep -oE '^[0-9.]+') |"
		sums+=("$(echo "$out" | grep -oE 'sum [0-9]+')")
	done
	echo "$line"
	# Every library must have found the same values
	if [ "$(printf '%s\n' "${sums[@]}" | sort -u | wc -l)" -ne 1 ]; then
		echo "sums differ for $name: ${sums[*]}" >&2
		exit 1
	fi
done
