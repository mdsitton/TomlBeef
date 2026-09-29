input: typed.toml, 3773397 bytes, 20000 [[servers]] with a nested table each

| library | language | mapping | read (ms) | read (MB/s) | write (ms) |
|---|---|---|---:|---:|---:|
| TomlBeef | Beef | [TomlObject], compile time | 41.138 | 87.5 | 24.202 |
| TomlBeef (no positions) | Beef | [TomlObject], compile time | 35.869 | 100.3 | 24.285 |
| glaze | C++ | reflection, compile time | 16.265 | 221.2 | 3.755 |
| toml-spanner | Rust | derive(Toml), compile time | 20.821 | 172.8 | 12.413 |
| toml (Rust) | Rust | serde derive, compile time | 78.522 | 45.8 | 28.975 |
| zig-toml | Zig | comptime reflection | 39.029 | 92.2 | n/a |
| go-toml | Go | struct tags, run-time reflection | 57.628 | 62.4 | 31.314 |
| BurntSushi | Go | struct tags, run-time reflection | 295.452 | 12.2 | 193.776 |
| Tomlyn (source generator) | C# | TomlSerializerContext, compile time | 126.344 | 28.5 | 46.087 |
| Tomlyn (reflection) | C# | run-time reflection | 145.033 | 24.8 | 50.121 |

TomlBeef: TomlSerializer.Read records source positions for located errors; "no positions" is doc.Read + doc.Deserialize without metadata. glaze skips UTF-8 validation; zig-toml accepts invalid TOML and cannot write an array of tables (n/a).
