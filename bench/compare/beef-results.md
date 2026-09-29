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
| Beef project files | 202.4 | 152.1 | 82.0 | yes (both read the same values; files either rejects are skipped) |
| commented | 432.0 | 615.2 | 296.0 | yes |
| comments | 800.0 | 2626.1 | 719.6 | yes |
| strings | 700.0 | 656.2 | 424.1 | yes |
| ints | 191.2 | 188.6 | 122.3 | yes |
| arrays | 124.3 | 79.7 | 32.5 | yes |
| headers | 117.9 | 94.4 | 58.1 | yes |
| floats | 204.1 | 169.3 | 96.3 | no: StructuredData parses float32 |
| dates | 259.7 | 187.5 | 119.7 | no: StructuredData keeps dates as text |

mixed and dotted: StructuredData cannot read them (literal strings, dotted keys).

### Key lookups (ns per lookup, lower is better)

| document | StructuredData (Open + TryGet) | TomlBeef |
|---|---:|---:|
| 200 tables × 1000 keys | 2025.9 | 74.7 |

### Writing (MB/s of output, higher is better)

| input | StructuredData ToTOML | TomlBeef Write |
|---|---:|---:|
| commented | 324.6 | 290.0 |
| strings | 369.3 | 241.8 |
| ints | 459.8 | 405.9 |
| arrays | 173.5 | 210.4 |
| headers | 258.1 | 271.1 |
