// Typed serialization of typed.toml (../typed.sh): tomlbench typed <burntsushi|gotoml> <read|write> <file> <min-samples>
// Both libraries map TOML to Go structs through `toml` struct tags. read times text -> new
// TypedRoot (MB/s of input); write times the model read once -> text (MB/s of output).
package main

import (
	"bytes"
	"fmt"
	"os"
	"strconv"

	burntsushi "github.com/BurntSushi/toml"
	gotoml "github.com/pelletier/go-toml/v2"
)

type TypedLimits struct {
	MaxConnections int32 `toml:"max_connections"`
	TimeoutMs      int32 `toml:"timeout_ms"`
}

type TypedServer struct {
	Name    string      `toml:"name"`
	Host    string      `toml:"host"`
	Port    int32       `toml:"port"`
	Enabled bool        `toml:"enabled"`
	Weight  float64     `toml:"weight"`
	Tags    []string    `toml:"tags"`
	Limits  TypedLimits `toml:"limits"`
}

type TypedRoot struct {
	Title   string        `toml:"title"`
	Version int32         `toml:"version"`
	Debug   bool          `toml:"debug"`
	Servers []TypedServer `toml:"servers"`
}

// check is "servers ports max_connections tags enabled", the same line every typed harness prints.
func (r *TypedRoot) check() string {
	var ports, connections, tags, enabled int64
	for _, s := range r.Servers {
		ports += int64(s.Port)
		connections += int64(s.Limits.MaxConnections)
		tags += int64(len(s.Tags))
		if s.Enabled {
			enabled++
		}
	}
	return fmt.Sprintf("check: %d %d %d %d %d", len(r.Servers), ports, connections, tags, enabled)
}

func typedBench(args []string) {
	lib, mode := args[2], args[3]
	data := mustRead(args[4])
	minSamples, err := strconv.Atoi(args[5])
	if err != nil {
		os.Exit(2)
	}

	read := func(text []byte) *TypedRoot {
		var root TypedRoot
		var err error
		if lib == "burntsushi" {
			_, err = burntsushi.Decode(string(text), &root)
		} else {
			err = gotoml.Unmarshal(text, &root)
		}
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		return &root
	}
	write := func(root *TypedRoot) []byte {
		if lib == "burntsushi" {
			var buf bytes.Buffer
			if err := burntsushi.NewEncoder(&buf).Encode(root); err != nil {
				fmt.Fprintln(os.Stderr, err)
				os.Exit(1)
			}
			return buf.Bytes()
		}
		out, err := gotoml.Marshal(root)
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		return out
	}

	model := read(data)
	fmt.Println(model.check())
	var median float64
	var n int
	var converged bool
	size := len(data)
	if mode == "read" {
		var sink *TypedRoot
		median, n, converged = measure(minSamples, func() { sink = read(data) })
		_ = sink
	} else {
		var output []byte
		median, n, converged = measure(minSamples, func() { output = write(model) })
		fmt.Println("re-read", read(output).check())
		size = len(output)
	}
	ms := median / 1e6
	status := "capped"
	if converged {
		status = "converged"
	}
	fmt.Printf("%.3f ms/op %.1f MB/s (n=%d, %s)\n", ms, float64(size)/1048576.0/(ms/1000.0), n, status)
}
