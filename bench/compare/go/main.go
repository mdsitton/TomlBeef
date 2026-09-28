// Go TOML benchmark: tomlbench <burntsushi|gotoml> <file> <iterations>
// Reads the file once, parses it once to warm up, then times up to <iterations> parses (3 s budget)
// into map[string]any (the schema-less form both libraries support).
//
//	burntsushi - github.com/BurntSushi/toml (toml.Decode)
//	gotoml     - github.com/pelletier/go-toml/v2 (toml.Unmarshal)
package main

import (
	"fmt"
	"os"
	"strconv"
	"time"

	burntsushi "github.com/BurntSushi/toml"
	gotoml "github.com/pelletier/go-toml/v2"
)

func main() {
	if len(os.Args) < 4 {
		fmt.Fprintln(os.Stderr, "usage: tomlbench <burntsushi|gotoml> <file> <iterations>")
		os.Exit(2)
	}
	mode := os.Args[1]
	data, err := os.ReadFile(os.Args[2])
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}
	iterations, err := strconv.Atoi(os.Args[3])
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}
	text := string(data)

	parse := func() error {
		var m map[string]any
		switch mode {
		case "burntsushi":
			_, err := burntsushi.Decode(text, &m)
			return err
		case "gotoml":
			return gotoml.Unmarshal(data, &m)
		}
		return fmt.Errorf("unknown mode %q", mode)
	}

	if err := parse(); err != nil {
		fmt.Fprintln(os.Stderr, "parse error:", err)
		os.Exit(1)
	}
	// Stop after <iterations> parses or 3 s, whichever comes first (at least one)
	start := time.Now()
	done := 0
	for done < iterations && (done == 0 || time.Since(start) < 3*time.Second) {
		parse()
		done++
	}
	ms := float64(time.Since(start).Nanoseconds()) / 1e6 / float64(done)
	fmt.Printf("%.3f ms/op %.1f MB/s\n", ms, float64(len(data))/1048576.0/(ms/1000.0))
}
