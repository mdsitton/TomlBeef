// Rust TOML benchmark: tomlbench <toml|edit|spanner|span> <file> <iterations>
// Reads the file once, parses it once to warm up, then times up to <iterations> parses within a
// 3 s budget.
//   toml     - toml::Table (the plain data model)
//   edit     - toml_edit::DocumentMut (format-preserving)
//   spanner  - toml_spanner::parse into a fresh Arena (span-preserving tree; arena freed per parse)
//   span     - toml_span::parse (span-preserving Value; no date/time support)
use std::time::Instant;

/// Key lookups after parsing (lookup.sh): tomlbench lookup <toml|edit|spanner> <file> <lookups> <passes>
/// Parses once, then times up to <passes> passes (3 s budget) over the `table key` pairs, each reading
/// the integer at root[table][key]. Prints ns per lookup and the sum of the values found.
fn lookup_bench(args: &[String]) {
    let (lib, text, pairs_text) = (args[2].as_str(), std::fs::read_to_string(&args[3]).expect("read"),
                                   std::fs::read_to_string(&args[4]).expect("read lookups"));
    let passes: usize = args[5].parse().expect("passes");
    let pairs: Vec<(&str, &str)> = pairs_text.lines().map(|l| l.split_once(' ').expect("pair")).collect();

    let run = |lookup: &dyn Fn(&str, &str) -> Option<i64>| {
        let start = Instant::now();
        let (mut done, mut sum, mut missing) = (0, 0i64, 0);
        while done < passes && (done == 0 || start.elapsed().as_secs_f64() < 3.0) {
            sum = 0;
            missing = 0;
            for (t, k) in &pairs {
                match std::hint::black_box(lookup(t, k)) {
                    Some(v) => sum += v,
                    None => missing += 1,
                }
            }
            done += 1;
        }
        let ns = start.elapsed().as_secs_f64() * 1e9 / (done * pairs.len()) as f64;
        println!("{ns:.1} ns/lookup, {} lookups, sum {sum}, missing {missing}", pairs.len());
    };

    match lib {
        "toml" => {
            let t: toml::Table = text.parse().expect("parse");
            run(&|a, b| t.get(a)?.as_table()?.get(b)?.as_integer());
        }
        "edit" => {
            let d: toml_edit::DocumentMut = text.parse().expect("parse");
            run(&|a, b| d.get(a)?.as_table()?.get(b)?.as_integer());
        }
        "spanner" => {
            let arena = toml_spanner::Arena::new();
            let d = toml_spanner::parse(&text, &arena).expect("parse");
            let root = d.table();
            run(&|a, b| root.get(a)?.as_table()?.get(b)?.as_i64());
        }
        _ => panic!("unknown library {lib}"),
    }
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() >= 6 && args[1] == "lookup" {
        lookup_bench(&args);
        return;
    }
    if args.len() < 4 {
        eprintln!("usage: tomlbench <toml|edit|spanner|span> <file> <iterations>");
        std::process::exit(2);
    }
    let mode = args[1].as_str();
    let text = std::fs::read_to_string(&args[2]).expect("read");
    let iterations: usize = args[3].parse().expect("iterations");

    let parse = |s: &str| -> Result<(), String> {
        match mode {
            "toml" => {
                let t: toml::Table = s.parse().map_err(|e| format!("{e}"))?;
                std::hint::black_box(t);
            }
            "edit" => {
                let d: toml_edit::DocumentMut = s.parse().map_err(|e| format!("{e}"))?;
                std::hint::black_box(d);
            }
            "spanner" => {
                let arena = toml_spanner::Arena::new();
                let d = toml_spanner::parse(s, &arena).map_err(|e| format!("{e:?}"))?;
                std::hint::black_box(&d);
            }
            "span" => {
                let v = toml_span::parse(s).map_err(|e| format!("{e:?}"))?;
                std::hint::black_box(v);
            }
            _ => return Err(format!("unknown mode {mode}")),
        }
        Ok(())
    };

    if let Err(e) = parse(&text) {
        eprintln!("parse error: {e}");
        std::process::exit(1);
    }
    // Stop after <iterations> parses or 3 s, whichever comes first (at least one)
    let start = Instant::now();
    let mut done = 0;
    while done < iterations && (done == 0 || start.elapsed().as_secs_f64() < 3.0) {
        parse(&text).unwrap();
        done += 1;
    }
    let ms = start.elapsed().as_secs_f64() * 1000.0 / done as f64;
    println!("{:.3} ms/op {:.1} MB/s", ms, text.len() as f64 / 1048576.0 / (ms / 1000.0));
}
