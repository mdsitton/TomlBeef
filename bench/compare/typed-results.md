input: typed.toml, 3773397 bytes, 20000 [[servers]] with a nested table each

| library | language | mapping | read (ms) | read (MB/s) | write (ms) |
|---|---|---|---:|---:|---:|
| TomlBeef | Beef | [TomlObject], compile time | 39.780 | 90.5 | 23.487 |
| TomlBeef (no positions) | Beef | [TomlObject], compile time | 34.000 | 105.8 | 23.427 |
| TomlBeef (arena) | Beef | [TomlObject], compile time | 37.315 | 96.4 | 23.247 |
| glaze | C++ | reflection, compile time | 16.064 | 224.0 | 3.746 |
| toml-spanner | Rust | derive(Toml), compile time | 20.842 | 172.7 | 12.286 |
| toml (Rust) | Rust | serde derive, compile time | 78.291 | 46.0 | 28.481 |
| zig-toml | Zig | comptime reflection | 38.885 | 92.5 | n/a |
| go-toml | Go | struct tags, run-time reflection | 55.472 | 64.9 | 30.310 |
| BurntSushi | Go | struct tags, run-time reflection | 294.292 | 12.2 | 200.040 |
| Tomlyn (source generator) | C# | TomlSerializerContext, compile time | 124.440 | 28.9 | 47.833 |
| Tomlyn (reflection) | C# | run-time reflection | 136.174 | 26.4 | 75.556 |

TomlBeef: TomlSerializer.Read records source positions for located errors; "no positions" is doc.Read + doc.Deserialize without metadata; "arena" is TomlSerializer.Read through a scope BumpAllocator (the write column repeats the plain write). glaze skips UTF-8 validation; zig-toml accepts invalid TOML and cannot write an array of tables (n/a).
