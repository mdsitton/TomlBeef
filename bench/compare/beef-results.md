### Values: does StructuredData read the same data?

```
mixed.toml: StructuredData error
commented.toml: exact match
comments.toml: exact match
strings.toml: exact match
ints.toml: exact match
floats.toml: match except 0 date/times kept as text, 200000 floats rounded to float32
dates.toml: match except 150000 date/times kept as text, 0 floats rounded to float32
arrays.toml: exact match
headers.toml: exact match
dotted.toml: StructuredData error
beef-projects: 134 files: 133 exact match, 0 match except date/time text or float32 (0 date/times, 0 floats), 0 values differ, 0 StructuredData error only, 1 TomlBeef error only, 0 both reject
toml-test valid: 266 files: 109 exact match, 32 match except date/time text or float32 (61 date/times, 9 floats), 4 values differ, 121 StructuredData error only, 0 TomlBeef error only, 0 both reject
toml-test invalid: 503 files: 4 exact match, 3 match except date/time text or float32 (3 date/times, 0 floats), 1 values differ, 3 StructuredData error only, 179 TomlBeef error only, 313 both reject
```

### Parsing (MB/s, higher is better)

| input | StructuredData | TomlBeef | TomlBeef preserve | like-for-like |
|---|---:|---:|---:|---|
| Beef project files | 206.0 | 109.0 | 64.7 | yes (both read the same values; files either rejects are skipped) |
| commented | 506.7 | 548.9 | 191.8 | yes |
| comments | 796.7 | 2923.1 | 735.9 | yes |
| strings | 677.9 | 660.1 | 296.6 | yes |
| ints | 213.4 | 155.6 | 96.9 | yes |
| arrays | 131.5 | 65.4 | 34.4 | yes |
| headers | 115.6 | 62.8 | 46.6 | yes |
| floats | 205.9 | 94.9 | 58.7 | no: StructuredData parses float32 |
| dates | 332.6 | 146.1 | 98.9 | no: StructuredData keeps dates as text |

mixed and dotted: StructuredData cannot read them (literal strings, dotted keys).

### Key lookups (ns per lookup, lower is better)

| document | StructuredData (Open + TryGet) | TomlBeef |
|---|---:|---:|
| 200 tables × 1000 keys | 2044.8 | 105.2 |

### Writing (MB/s of output, higher is better)

| input | StructuredData ToTOML | TomlBeef Write |
|---|---:|---:|
| commented | 334.5 | 243.9 |
| strings | 369.2 | 240.5 |
| ints | 458.4 | 236.1 |
| arrays | 162.8 | 180.8 |
| headers | 255.1 | 173.2 |
