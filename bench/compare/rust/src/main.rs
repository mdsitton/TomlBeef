// toml / toml_edit benchmark: tomlbench <toml|edit> <file> <iterations>
// Reads the file once, parses it once to warm up, then times up to <iterations> parses within a
// 3 s budget.
//   toml  - toml::Table (the plain data model)
//   edit  - toml_edit::DocumentMut (format-preserving)
use std::time::Instant;

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 4 {
        eprintln!("usage: tomlbench <toml|edit> <file> <iterations>");
        std::process::exit(2);
    }
    let mode = args[1].as_str();
    let text = std::fs::read_to_string(&args[2]).expect("read");
    let iterations: usize = args[3].parse().expect("iterations");

    let parse = |s: &str| match mode {
        "toml" => {
            let t: toml::Table = s.parse().expect("parse");
            std::hint::black_box(t);
        }
        "edit" => {
            let d: toml_edit::DocumentMut = s.parse().expect("parse");
            std::hint::black_box(d);
        }
        _ => panic!("unknown mode"),
    };

    parse(&text);
    // Stop after <iterations> parses or 3 s, whichever comes first (at least one)
    let start = Instant::now();
    let mut done = 0;
    while done < iterations && (done == 0 || start.elapsed().as_secs_f64() < 3.0) {
        parse(&text);
        done += 1;
    }
    let ms = start.elapsed().as_secs_f64() * 1000.0 / done as f64;
    println!("{:.3} ms/op {:.1} MB/s", ms, text.len() as f64 / 1048576.0 / (ms / 1000.0));
}
