#!/bin/bash
# Builds every comparison harness into bin/ (git-ignored), plus TomlBeef's own TomlTester in
# Release. Run fetch.sh first. C and C++ use -O3 without -march=native, like TomlBeef's Release
# build (generic x86-64). Pass the names of harnesses to build only those.
set -euo pipefail
C="$(cd "$(dirname "$0")" && pwd)"
D="$C/deps"
B="$C/bin"
mkdir -p "$B"

TARGETS=("$@")
want() { [ ${#TARGETS[@]} -eq 0 ] || [[ " ${TARGETS[*]} " == *" $1 "* ]]; }
step() { echo "== $1"; }

if want tomlbeef; then
	step tomlbeef
	(cd "$C/../.." && beefbuild -config=Release > /dev/null)
fi
if want tomlc17; then
	step tomlc17
	cc -O3 -std=gnu11 -I"$D/tomlc17/src" -o "$B/tomlc17" "$C/c/tomlc17.c" "$D/tomlc17/src/tomlc17.c"
fi
if want toml-c; then
	step toml-c
	cc -O3 -std=gnu11 -I"$D/toml-c" -o "$B/toml-c" "$C/c/toml-c.c" "$D/toml-c/toml.c"
fi
if want toml11; then
	step toml11
	c++ -O3 -std=c++17 -I"$D/toml11/include" -o "$B/toml11" "$C/cpp/toml11.cpp"
fi
if want tomlplusplus; then
	step tomlplusplus
	c++ -O3 -std=c++17 -DTOML_EXCEPTIONS=0 -I"$D/tomlplusplus/include" -o "$B/tomlplusplus" "$C/cpp/tomlplusplus.cpp"
fi
if want glaze; then
	step glaze
	c++ -O3 -std=c++23 -I"$D/glaze/include" -o "$B/glaze" "$C/cpp/glaze.cpp"
fi
if want rust; then
	step "rust (toml, toml_edit, toml-spanner, toml-span)"
	# Built from its directory so rustup picks the pinned toolchain in rust-toolchain.toml
	(cd "$C/rust" && cargo build -q --release --target-dir "$C/rust/target")
	cp "$C/rust/target/release/tomlbench" "$B/rust-tomlbench"
fi
if want go; then
	step "go (BurntSushi/toml, go-toml)"
	(cd "$C/go" && go build -o "$B/go-tomlbench" .)
fi
if want zig-toml; then
	step zig-toml
	(cd "$C/zig" && "$D/zig/zig" build-exe -O ReleaseFast --dep toml -Mroot=bench.zig -Mtoml="$D/zig-toml/src/root.zig" \
		-femit-bin="$B/zig-toml" --cache-dir "$C/zig/.zig-cache" --global-cache-dir "$C/zig/.zig-cache")
fi
if want java; then
	step "java (tomlj, jtoml)"
	(cd "$C/java" && gradle -q --console=plain installDist)
	rm -rf "$B/java" && cp -r "$C/java/build/install/tomlbench" "$B/java"
fi
if want js; then
	step "javascript (js-toml, smol-toml, toml)"
	(cd "$C/js" && npm install --silent --no-audit --no-fund)
fi
if want beef; then
	step "beef (TomlBeef vs Beef's StructuredData)"
	(cd "$C/beef" && beefbuild -config=Release > /dev/null)
fi
if want tomlyn; then
	step tomlyn
	dotnet build -v q -nologo -c Release -o "$B/tomlyn" "$C/cs/TomlynBench.csproj" > /dev/null
fi
