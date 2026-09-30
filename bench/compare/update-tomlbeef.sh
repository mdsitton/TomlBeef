#!/bin/bash
# Refreshes every TomlBeef figure without rerunning the other libraries (the full suite takes hours):
# rebuilds TomlBeef's harnesses, remeasures the TomlBeef columns and rows of results.md,
# lookup-results.md and typed-results.md (ONLY, see merge.sh; the other libraries keep their saved
# figures), reruns modes.sh and beef.sh (TomlBeef and Beef's own reader only), and redraws the charts.
# Timings follow the rule in run.sh. A step that fails leaves its results file unchanged.
# Usage: update-tomlbeef.sh [min-samples]   (after ./fetch.sh && ./gen-inputs.py, once)
set -uo pipefail
C="$(cd "$(dirname "$0")" && pwd)"
N="${1:-5}"

# The saved figures of the other libraries came from a quiet machine; TomlBeef's must too, or the
# comparison is off (a run at load average 20 read up to a third slow and varied 2× between runs).
# FORCE=1 runs anyway.
load=$(cut -d' ' -f1 /proc/loadavg)
if [ -z "${FORCE:-}" ] && awk -v l="$load" 'BEGIN { exit !(l > 2) }'; then
	echo "Load average is $load: close other work and rerun (or FORCE=1 to measure anyway)" >&2
	exit 1
fi
export ONLY='TomlBeef.*'
status=0

step() { echo; echo "== $1"; }

# Saves a whole-table script's output only if it succeeded
save() { # results-file command...
	local file="$1" tmp
	shift
	tmp=$(mktemp)
	if "$@" | tee "$tmp" && [ "${PIPESTATUS[0]}" -eq 0 ]; then
		mv "$tmp" "$file"
	else
		rm -f "$tmp"
		echo "not saved: $file" >&2
		status=1
	fi
}

step "build (TomlTester and BeefTomlBench, Release)"
"$C/build.sh" tomlbeef beef || exit 1

step "parsing: results.md"
"$C/run.sh" "$N" || status=1
step "lookups: lookup-results.md"
"$C/lookup.sh" "$N" || status=1
step "typed: typed-results.md"
"$C/typed.sh" "$N" || status=1

unset ONLY
step "modes: modes-results.md"
save "$C/modes-results.md" "$C/modes.sh" "$N"
step "Beef StructuredData: beef-results.md"
save "$C/beef-results.md" "$C/beef.sh" "$N"

step "charts"
"$C/plot.py" || status=1
exit $status
