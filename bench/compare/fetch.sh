#!/bin/bash
# Clones the C and C++ libraries the comparison benchmark builds against into deps/ (git-ignored),
# each at a pinned release so runs are comparable. The Rust, Go and .NET libraries are pinned in
# rust/Cargo.toml, go/go.mod and cs/TomlynBench.csproj and fetched by their own tools.
set -euo pipefail
C="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$C/deps"

fetch() { # name url ref
	local dir="$C/deps/$1"
	if [ -d "$dir/.git" ]; then
		git -C "$dir" fetch -q --depth 1 origin "$3"
	else
		git init -q "$dir"
		git -C "$dir" remote add origin "$2"
		git -C "$dir" fetch -q --depth 1 origin "$3"
	fi
	git -C "$dir" checkout -q --detach FETCH_HEAD
	echo "$1 $(git -C "$dir" rev-parse --short HEAD) ($3)"
}

fetch tomlc17     https://github.com/cktan/tomlc17        R260821
fetch toml-c      https://github.com/arp242/toml-c        6a38d404184a3b399d61821dbfff229579d59a00
fetch toml11      https://github.com/ToruNiina/toml11     v4.4.0
fetch tomlplusplus https://github.com/marzer/tomlplusplus v3.4.0
fetch glaze       https://github.com/stephenberry/glaze   v9.0.0
