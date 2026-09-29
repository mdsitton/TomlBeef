// Go TOML benchmark: tomlbench <burntsushi|gotoml> <file> <min-samples>
// Parse mode times single parses into map[string]any (the schema-less form both libraries support)
// under the shared rule (see measure and run.sh).
//
//	burntsushi - github.com/BurntSushi/toml (toml.Decode)
//	gotoml     - github.com/pelletier/go-toml/v2 (toml.Unmarshal)
//
// Key lookups (lookup.sh): tomlbench lookup <burntsushi|gotoml> <file> <lookups> <min-samples>
package main

import (
	"fmt"
	"os"
	"sort"
	"strconv"
	"strings"
	"time"

	burntsushi "github.com/BurntSushi/toml"
	gotoml "github.com/pelletier/go-toml/v2"
)

// measure warms up for at least 1 s (at least one run), then times single runs until at least
// minSamples were taken and at least 60% lie within ±10% of their median ("converged"), or 10 s of
// measuring or 1000 samples have passed. Returns the median sample in ns.
func measure(minSamples int, op func()) (median float64, n int, converged bool) {
	warm := time.Now()
	for {
		op()
		if time.Since(warm) >= time.Second {
			break
		}
	}
	start := time.Now()
	var samples []float64
	for {
		t0 := time.Now()
		op()
		samples = append(samples, float64(time.Since(t0).Nanoseconds()))
		sorted := append([]float64(nil), samples...)
		sort.Float64s(sorted)
		n = len(sorted)
		if n%2 == 1 {
			median = sorted[n/2]
		} else {
			median = (sorted[n/2-1] + sorted[n/2]) / 2
		}
		if n >= minSamples {
			within := 0
			for _, s := range samples {
				if s >= median*0.9 && s <= median*1.1 {
					within++
				}
			}
			if float64(within) >= 0.6*float64(n) {
				return median, n, true
			}
		}
		if n >= 1000 || time.Since(start) >= 10*time.Second {
			return median, n, false
		}
	}
}

func status(converged bool) string {
	if converged {
		return "converged"
	}
	return "capped"
}

func decode(lib string, data []byte) (map[string]any, error) {
	var m map[string]any
	switch lib {
	case "burntsushi":
		_, err := burntsushi.Decode(string(data), &m)
		return m, err
	case "gotoml":
		return m, gotoml.Unmarshal(data, &m)
	}
	return nil, fmt.Errorf("unknown library %q", lib)
}

func mustRead(path string) []byte {
	data, err := os.ReadFile(path)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}
	return data
}

// lookupBench parses once, then measures passes over the `table key` pairs, each reading the
// integer at root[table][key] from the decoded map.
func lookupBench(args []string) {
	root, err := decode(args[2], mustRead(args[3]))
	if err != nil {
		fmt.Fprintln(os.Stderr, "parse error:", err)
		os.Exit(1)
	}
	minSamples, _ := strconv.Atoi(args[5])
	var tables, keys []string
	for _, line := range strings.Split(strings.TrimRight(string(mustRead(args[4])), "\n"), "\n") {
		t, k, _ := strings.Cut(line, " ")
		tables = append(tables, t)
		keys = append(keys, k)
	}
	var sum int64
	missing := 0
	median, n, converged := measure(minSamples, func() {
		sum, missing = 0, 0
		for i := range tables {
			if t, ok := root[tables[i]].(map[string]any); ok {
				if v, ok := t[keys[i]].(int64); ok {
					sum += v
					continue
				}
			}
			missing++
		}
	})
	fmt.Printf("%.1f ns/lookup, %d lookups, sum %d, missing %d (n=%d, %s)\n",
		median/float64(len(tables)), len(tables), sum, missing, n, status(converged))
}

func main() {
	if len(os.Args) >= 6 && os.Args[1] == "typed" {
		typedBench(os.Args)
		return
	}
	if len(os.Args) >= 6 && os.Args[1] == "lookup" {
		lookupBench(os.Args)
		return
	}
	if len(os.Args) < 4 {
		fmt.Fprintln(os.Stderr, "usage: tomlbench <burntsushi|gotoml> <file> <min-samples>")
		os.Exit(2)
	}
	lib := os.Args[1]
	data := mustRead(os.Args[2])
	minSamples, err := strconv.Atoi(os.Args[3])
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}
	if _, err := decode(lib, data); err != nil {
		fmt.Fprintln(os.Stderr, "parse error:", err)
		os.Exit(1)
	}
	median, n, converged := measure(minSamples, func() { decode(lib, data) })
	ms := median / 1e6
	fmt.Printf("%.3f ms/op %.1f MB/s (n=%d, %s)\n", ms, float64(len(data))/1048576.0/(ms/1000.0), n, status(converged))
}
