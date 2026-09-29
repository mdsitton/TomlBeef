// Rust TOML benchmark: tomlbench <toml|edit|spanner|span> <file> <min-samples>
// Parse mode times single parses under the shared rule (see `measure` and run.sh).
//   toml     - toml::Table (the plain data model)
//   edit     - toml_edit::DocumentMut (format-preserving)
//   spanner  - toml_spanner::parse into a fresh Arena (span-preserving tree; arena freed per parse)
//   span     - toml_span::parse (span-preserving Value; no date/time support)
// Typed serialization (typed.sh): tomlbench typed <serde|spanner> <read|write> <file> <min-samples>, see typed.rs
use std::time::Instant;

mod typed;

/// The rule shared by every harness in bench/compare: warm up for at least 1 s (at least one run),
/// then time single runs until at least `min_samples` were taken and at least 60% of them lie within
/// ±10% of their median ("converged"), or 10 s of measuring or 1000 samples have passed. Returns the
/// median sample in ns, the sample count and whether it converged.
fn measure(min_samples: usize, mut op: impl FnMut()) -> (f64, usize, bool) {
    let warm = Instant::now();
    loop {
        op();
        if warm.elapsed().as_secs_f64() >= 1.0 {
            break;
        }
    }
    let start = Instant::now();
    let mut samples: Vec<f64> = Vec::new();
    loop {
        let t0 = Instant::now();
        op();
        samples.push(t0.elapsed().as_nanos() as f64);
        let mut sorted = samples.clone();
        sorted.sort_by(|a, b| a.partial_cmp(b).unwrap());
        let n = sorted.len();
        let median = if n % 2 == 1 { sorted[n / 2] } else { (sorted[n / 2 - 1] + sorted[n / 2]) / 2.0 };
        if n >= min_samples {
            let within = samples.iter().filter(|&&s| s >= median * 0.9 && s <= median * 1.1).count();
            if within as f64 >= 0.6 * n as f64 {
                return (median, n, true);
            }
        }
        if n >= 1000 || start.elapsed().as_secs_f64() >= 10.0 {
            return (median, n, false);
        }
    }
}

fn status(converged: bool) -> &'static str {
    if converged { "converged" } else { "capped" }
}

/// Key lookups after parsing (lookup.sh): tomlbench lookup <toml|edit|spanner|span> <file> <lookups> <min-samples>
/// Parses once, then measures passes over the `table key` pairs, each reading the integer at
/// root[table][key]. Prints ns per lookup and the sum of the values found.
fn lookup_bench(args: &[String]) {
    let (lib, text, pairs_text) = (args[2].as_str(), std::fs::read_to_string(&args[3]).expect("read"),
                                   std::fs::read_to_string(&args[4]).expect("read lookups"));
    let min_samples: usize = args[5].parse().expect("min samples");
    let pairs: Vec<(&str, &str)> = pairs_text.lines().map(|l| l.split_once(' ').expect("pair")).collect();

    let run = |lookup: &dyn Fn(&str, &str) -> Option<i64>| {
        let (mut sum, mut missing) = (0i64, 0);
        let (median, n, converged) = measure(min_samples, || {
            sum = 0;
            missing = 0;
            for (t, k) in &pairs {
                match std::hint::black_box(lookup(t, k)) {
                    Some(v) => sum += v,
                    None => missing += 1,
                }
            }
        });
        println!("{:.1} ns/lookup, {} lookups, sum {sum}, missing {missing} (n={n}, {})",
                 median / pairs.len() as f64, pairs.len(), status(converged));
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
        "span" => {
            let v = match toml_span::parse(&text) {
                Ok(v) => v,
                Err(e) => {
                    eprintln!("parse error: {e:?}");
                    std::process::exit(1);
                }
            };
            let root = v.as_table().expect("root table");
            run(&|a, b| root.get(a)?.as_table()?.get(b)?.as_integer());
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
    if args.len() >= 6 && args[1] == "typed" {
        typed::typed_bench(&args);
        return;
    }
    if args.len() < 4 {
        eprintln!("usage: tomlbench <toml|edit|spanner|span> <file> <min-samples>");
        std::process::exit(2);
    }
    let mode = args[1].as_str();
    let text = std::fs::read_to_string(&args[2]).expect("read");
    let min_samples: usize = args[3].parse().expect("min samples");

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
    let (median, n, converged) = measure(min_samples, || parse(&text).unwrap());
    let ms = median / 1e6;
    println!("{:.3} ms/op {:.1} MB/s (n={n}, {})", ms, text.len() as f64 / 1048576.0 / (ms / 1000.0), status(converged));
}
