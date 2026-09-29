// Typed serialization of typed.toml (../typed.sh): tomlbench typed <serde|spanner> <read|write> <file> <min-samples>
//   serde   - the toml crate with serde derive: toml::from_str / toml::to_string
//   spanner - toml-spanner's own derive (FromToml, ToToml): from_str / to_string
// read times text -> new TypedRoot (MB/s of input); write times the model read once -> text (MB/s of output).
use serde::{Deserialize, Serialize};
use toml_spanner::Toml;

#[derive(Deserialize, Serialize, Toml)]
#[toml(FromToml, ToToml)]
struct TypedLimits {
    max_connections: i32,
    timeout_ms: i32,
}

#[derive(Deserialize, Serialize, Toml)]
#[toml(FromToml, ToToml)]
struct TypedServer {
    name: String,
    host: String,
    port: i32,
    enabled: bool,
    weight: f64,
    tags: Vec<String>,
    limits: TypedLimits,
}

#[derive(Deserialize, Serialize, Toml)]
#[toml(FromToml, ToToml)]
struct TypedRoot {
    title: String,
    version: i32,
    debug: bool,
    servers: Vec<TypedServer>,
}

impl TypedRoot {
    // "servers ports max_connections tags enabled", the same line every typed harness prints
    fn check(&self) -> String {
        let s = &self.servers;
        format!("check: {} {} {} {} {}", s.len(),
            s.iter().map(|x| x.port as i64).sum::<i64>(),
            s.iter().map(|x| x.limits.max_connections as i64).sum::<i64>(),
            s.iter().map(|x| x.tags.len()).sum::<usize>(),
            s.iter().filter(|x| x.enabled).count())
    }
}

pub fn typed_bench(args: &[String]) {
    let (lib, mode) = (args[2].as_str(), args[3].as_str());
    let text = std::fs::read_to_string(&args[4]).expect("read");
    let min_samples: usize = args[5].parse().expect("min samples");

    let read = |s: &str| -> TypedRoot {
        match lib {
            "serde" => toml::from_str(s).expect("serde read"),
            _ => toml_spanner::from_str(s).expect("spanner read"),
        }
    };
    let write = |root: &TypedRoot| -> String {
        match lib {
            "serde" => toml::to_string(root).expect("serde write"),
            _ => toml_spanner::to_string(root).expect("spanner write"),
        }
    };

    let model = read(&text);
    println!("{}", model.check());
    let (median, samples, converged, bytes) = if mode == "read" {
        let (m, n, c) = crate::measure(min_samples, || { std::hint::black_box(read(&text)); });
        (m, n, c, text.len())
    } else {
        let mut output = String::new();
        let (m, n, c) = crate::measure(min_samples, || { output = write(&model); });
        println!("re-read {}", read(&output).check());
        (m, n, c, output.len())
    };
    let ms = median / 1e6;
    println!("{:.3} ms/op {:.1} MB/s (n={}, {})", ms, bytes as f64 / 1048576.0 / (ms / 1000.0), samples,
        if converged { "converged" } else { "capped" });
}
