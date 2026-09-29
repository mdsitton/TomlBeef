#!/bin/bash
# Typed serialization: each library reads inputs/typed.toml into its own native types (structs or
# classes declared to match; see gen-inputs.py `typed`) and writes them back to TOML. Only libraries
# with a typed mapping take part. Every harness prints the same checksum line after reading, and
# again after re-reading its own output, so all of them bind the same values.
# Times are ms per operation (the data is the same for everyone; written text differs in layout, so
# write MB/s would reward longer output). Timings follow the rule in run.sh; each cell is the median
# of REPEATS processes (default 3), a run past LIMIT seconds (default 60) is DNF.
# Usage: typed.sh [min-samples]   (after ./fetch.sh && ./build.sh && ./gen-inputs.py)
set -uo pipefail
C="$(cd "$(dirname "$0")" && pwd)"
B="$C/bin"
N="${1:-5}"
REPEATS="${REPEATS:-3}"
LIMIT="${LIMIT:-60}"
IN="$C/inputs/typed.toml"
CHECK="check: 20000 179815164 101543836 60000 13333"

# Median over REPEATS runs of a harness's "<ms> ms/op" figure; DNF past the limit, FAIL on an error or
# a checksum that differs, "n/a" when the library cannot do it (exit 3)
median() { # command...
	local values=() out status
	for ((r = 0; r < REPEATS; r++)); do
		out=$(timeout "$LIMIT" "$@" 2>&1)
		status=$?
		if [ $status -eq 124 ]; then echo DNF; return; fi
		if [ $status -eq 3 ]; then echo "n/a"; return; fi
		if [ $status -ne 0 ] || ! grep -q "^$CHECK" <<< "$out" || { grep -q "^re-read" <<< "$out" && ! grep -q "^re-read $CHECK" <<< "$out"; }; then
			echo FAIL
			return
		fi
		values+=("$(grep -oE '[0-9.]+ ms/op' <<< "$out" | awk '{print $1}')")
	done
	printf '%s\n' "${values[@]}" | sort -g | awk '{a[NR] = $1} END {print (NR % 2) ? a[(NR + 1) / 2] : (a[NR / 2] + a[NR / 2 + 1]) / 2}'
}

mbps() { # ms -> MB/s of the input
	awk -v ms="$1" -v bytes="$(stat -c %s "$IN")" 'BEGIN { if (ms + 0 > 0) printf "%.1f", bytes / 1048576 / (ms / 1000); else print "" }'
}

BEEF="$C/beef/build/Release_Linux64/BeefTomlBench/BeefTomlBench"
row() { # name language how read-command... -- write-command...
	local name="$1" language="$2" how="$3"
	shift 3
	local read=() write=()
	while [ "$1" != "--" ]; do read+=("$1"); shift; done
	shift
	write=("$@")
	local r w
	r=$(median "${read[@]}")
	w=$(median "${write[@]}")
	echo "| $name | $language | $how | $r | $(mbps "$r") | $w |"
}

echo "input: typed.toml, $(stat -c %s "$IN") bytes, 20000 [[servers]] with a nested table each"
echo
echo "| library | language | mapping | read (ms) | read (MB/s) | write (ms) |"
echo "|---|---|---|---:|---:|---:|"
row TomlBeef Beef "[TomlObject], compile time" "$BEEF" typed read "$IN" "$N" -- "$BEEF" typed write "$IN" "$N"
row "TomlBeef (no positions)" Beef "[TomlObject], compile time" "$BEEF" typed read-plain "$IN" "$N" -- "$BEEF" typed write "$IN" "$N"
row "TomlBeef (arena)" Beef "[TomlObject], compile time" "$BEEF" typed read-arena "$IN" "$N" -- "$BEEF" typed write "$IN" "$N"
row glaze C++ "reflection, compile time" "$B/glaze-typed" read "$IN" "$N" -- "$B/glaze-typed" write "$IN" "$N"
row toml-spanner Rust "derive(Toml), compile time" "$B/rust-tomlbench" typed spanner read "$IN" "$N" -- "$B/rust-tomlbench" typed spanner write "$IN" "$N"
row "toml (Rust)" Rust "serde derive, compile time" "$B/rust-tomlbench" typed serde read "$IN" "$N" -- "$B/rust-tomlbench" typed serde write "$IN" "$N"
row zig-toml Zig "comptime reflection" "$B/zig-toml-typed" read "$IN" "$N" -- "$B/zig-toml-typed" write "$IN" "$N"
row go-toml Go "struct tags, run-time reflection" "$B/go-tomlbench" typed gotoml read "$IN" "$N" -- "$B/go-tomlbench" typed gotoml write "$IN" "$N"
row BurntSushi Go "struct tags, run-time reflection" "$B/go-tomlbench" typed burntsushi read "$IN" "$N" -- "$B/go-tomlbench" typed burntsushi write "$IN" "$N"
row "Tomlyn (source generator)" "C#" "TomlSerializerContext, compile time" "$B/tomlyn/TomlynBench" typed sourcegen read "$IN" "$N" -- "$B/tomlyn/TomlynBench" typed sourcegen write "$IN" "$N"
row "Tomlyn (reflection)" "C#" "run-time reflection" "$B/tomlyn/TomlynBench" typed reflection read "$IN" "$N" -- "$B/tomlyn/TomlynBench" typed reflection write "$IN" "$N"
echo
echo "TomlBeef: TomlSerializer.Read records source positions for located errors; \"no positions\" is doc.Read + doc.Deserialize without metadata; \"arena\" is TomlSerializer.Read through a scope BumpAllocator (the write column repeats the plain write). glaze skips UTF-8 validation; zig-toml accepts invalid TOML and cannot write an array of tables (n/a)."
