// JavaScript TOML benchmark: node bench.mjs <js-toml|smol-toml|toml> <file> <iterations>
// Reads the file once, warms up for 1 s (at least one parse) so V8 has optimised the parser, then
// times up to <iterations> parses within a 3 s budget. Each library parses into plain objects.
//   js-toml   - sunnyadn/js-toml (load)
//   smol-toml - squirrelchat/smol-toml (parse)
//   toml      - BinaryMuse/toml-node (parse)
import { readFileSync } from "node:fs";
import { load as jsTomlLoad } from "js-toml";
import { parse as smolParse } from "smol-toml";
import toml from "toml";

const [mode, file, iterationsArg] = process.argv.slice(2);
if (!iterationsArg) {
  console.error("usage: node bench.mjs <js-toml|smol-toml|toml> <file> <iterations>");
  process.exit(2);
}
const bytes = readFileSync(file);
const text = bytes.toString("utf8");
const iterations = Number(iterationsArg);
const parsers = { "js-toml": jsTomlLoad, "smol-toml": smolParse, "toml": (s) => toml.parse(s) };
const parse = parsers[mode];
if (!parse) {
  console.error(`unknown mode ${mode}`);
  process.exit(2);
}

let sink;
try {
  const warmStart = process.hrtime.bigint();
  do {
    sink = parse(text);
  } while (process.hrtime.bigint() - warmStart < 1_000_000_000n);
} catch (e) {
  console.error(`parse error: ${e.message}`);
  process.exit(1);
}

// Stop after <iterations> parses or 3 s, whichever comes first (at least one)
const start = process.hrtime.bigint();
let done = 0;
while (done < iterations && (done === 0 || process.hrtime.bigint() - start < 3_000_000_000n)) {
  sink = parse(text);
  done++;
}
const ms = Number(process.hrtime.bigint() - start) / 1e6 / done;
console.log(`${ms.toFixed(3)} ms/op ${(bytes.length / 1048576 / (ms / 1000)).toFixed(1)} MB/s`);
