input: typed.toml, 3773397 bytes

| operation | mode | ms |
|---|---|---:|
| read | Document | 25.127 |
| read | Document + positions | 30.033 |
| read | Document + PreserveStyle | 48.555 |
| read | Typed | 35.020 |
| read | Typed + positions | 41.290 |
| read | Typed + positions, arena | 39.356 |
| write | Document | 11.786 |
| write | Document + PreserveStyle | 16.502 |
| write | Typed | 24.802 |
| write | Typed update + PreserveStyle | 22.042 |
