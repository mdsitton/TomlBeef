// JavaScript TOML benchmark: node bench.mjs <js-toml|smol-toml|toml> <file> <min-samples>
// Parse mode times single parses into plain objects under the shared rule (see measure and run.sh);
// the 1 s warm-up also lets V8 optimise the parser.
//   js-toml   - sunnyadn/js-toml (load)
//   smol-toml - squirrelchat/smol-toml (parse)
//   toml      - BinaryMuse/toml-node (parse)
// Key lookups (lookup.sh): node bench.mjs lookup <lib> <file> <lookups> <min-samples>
import { readFileSync } from "node:fs";
import { load as jsTomlLoad } from "js-toml";
import { parse as smolParse } from "smol-toml";
import toml from "toml";

const parsers = { "js-toml": jsTomlLoad, "smol-toml": smolParse, "toml": (s) => toml.parse(s) };
const now = () => process.hrtime.bigint();

// Warm up for at least 1 s (at least one run), then time single runs until at least minSamples were
// taken and at least 60% lie within ±10% of their median, or 10 s / 1000 samples have passed.
function measure(minSamples, op) {
  const warm = now();
  do op(); while (now() - warm < 1_000_000_000n);
  const start = now();
  const samples = [];
  for (;;) {
    const t0 = now();
    op();
    samples.push(Number(now() - t0));
    const sorted = [...samples].sort((a, b) => a - b);
    const n = sorted.length;
    const median = n % 2 ? sorted[(n - 1) / 2] : (sorted[n / 2 - 1] + sorted[n / 2]) / 2;
    if (n >= minSamples && samples.filter((s) => s >= median * 0.9 && s <= median * 1.1).length >= 0.6 * n)
      return { median, n, status: "converged" };
    if (n >= 1000 || now() - start >= 10_000_000_000n) return { median, n, status: "capped" };
  }
}

function parseOrExit(parse, text) {
  try {
    return parse(text);
  } catch (e) {
    console.error(`parse error: ${e.message}`);
    process.exit(1);
  }
}

// Key lookups after parsing: parses once, then measures passes, each reading the integer at
// root[table][key]. js-toml and smol-toml return BigInt or Number depending on size, toml Number.
if (process.argv[2] === "lookup") {
  const [, , , lib, file, lookupsFile, minArg] = process.argv;
  const root = parseOrExit(parsers[lib], readFileSync(file, "utf8"));
  const lines = readFileSync(lookupsFile, "utf8").trimEnd().split("\n");
  const tables = lines.map((l) => l.slice(0, l.indexOf(" ")));
  const keys = lines.map((l) => l.slice(l.indexOf(" ") + 1));
  let sum = 0n, missing = 0;
  const m = measure(Number(minArg), () => {
    sum = 0n;
    missing = 0;
    for (let i = 0; i < tables.length; i++) {
      const table = root[tables[i]];
      const v = table !== null && typeof table === "object" ? table[keys[i]] : undefined;
      if (typeof v === "number" || typeof v === "bigint") sum += BigInt(v);
      else missing++;
    }
  });
  console.log(`${(m.median / tables.length).toFixed(1)} ns/lookup, ${tables.length} lookups, sum ${sum}, missing ${missing} (n=${m.n}, ${m.status})`);
  process.exit(0);
}

const [mode, file, minArg] = process.argv.slice(2);
if (!minArg || !parsers[mode]) {
  console.error("usage: node bench.mjs <js-toml|smol-toml|toml> <file> <min-samples>");
  process.exit(2);
}
const bytes = readFileSync(file);
const text = bytes.toString("utf8");
const parse = parsers[mode];
let sink = parseOrExit(parse, text);
const m = measure(Number(minArg), () => { sink = parse(text); });
const ms = m.median / 1e6;
console.log(`${ms.toFixed(3)} ms/op ${(bytes.length / 1048576 / (ms / 1000)).toFixed(1)} MB/s (n=${m.n}, ${m.status})`);
