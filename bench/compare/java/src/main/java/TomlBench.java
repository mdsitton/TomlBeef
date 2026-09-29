// Java TOML benchmark: tomlbench <tomlj|jtoml> <file> <min-samples>
// Parse mode times single parses under the shared rule (see measure and run.sh); the 1 s warm-up also
// lets the JIT compile the parser.
//   tomlj - org.tomlj.Toml.parse (TomlParseResult; errors are collected, not thrown)
//   jtoml - JToml.readFromString (TomlDocument, which also keeps comments)
// Key lookups (lookup.sh): tomlbench lookup <tomlj|jtoml> <file> <lookups> <min-samples>
import io.github.wasabithumb.jtoml.JToml;
import io.github.wasabithumb.jtoml.document.TomlDocument;
import io.github.wasabithumb.jtoml.key.TomlKey;
import io.github.wasabithumb.jtoml.value.TomlValue;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import org.tomlj.Toml;
import org.tomlj.TomlParseResult;

public final class TomlBench {
    static volatile Object sink;

    record Measurement(double medianNs, int samples, boolean converged) {
        String status() {
            return converged ? "converged" : "capped";
        }
    }

    /**
     * Warm up for at least 1 s (at least one run), then time single runs until at least minSamples
     * were taken and at least 60% lie within ±10% of their median, or 10 s / 1000 samples have passed.
     */
    static Measurement measure(int minSamples, Runnable op) {
        long warm = System.nanoTime();
        do {
            op.run();
        } while (System.nanoTime() - warm < 1_000_000_000L);
        long start = System.nanoTime();
        double[] samples = new double[1000];
        int n = 0;
        while (true) {
            long t0 = System.nanoTime();
            op.run();
            samples[n++] = System.nanoTime() - t0;
            double[] sorted = Arrays.copyOf(samples, n);
            Arrays.sort(sorted);
            double median = n % 2 == 1 ? sorted[n / 2] : (sorted[n / 2 - 1] + sorted[n / 2]) / 2;
            if (n >= minSamples) {
                int within = 0;
                for (int i = 0; i < n; i++)
                    if (samples[i] >= median * 0.9 && samples[i] <= median * 1.1)
                        within++;
                if (within >= 0.6 * n)
                    return new Measurement(median, n, true);
            }
            if (n >= 1000 || System.nanoTime() - start >= 10_000_000_000L)
                return new Measurement(median, n, false);
        }
    }

    /** A key lookup: the integer at root[table][key], or null. */
    interface Lookup {
        Long get(int i);
    }

    /**
     * Key lookups after parsing: parses once (untimed), builds each library's key objects up front,
     * then measures passes over all lookups.
     */
    static void lookupBench(String[] args) throws Exception {
        String lib = args[1];
        String text = Files.readString(Path.of(args[2]));
        List<String> lines = Files.readAllLines(Path.of(args[3]));
        int minSamples = Integer.parseInt(args[4]);
        int n = lines.size();
        String[] tables = new String[n], keys = new String[n];
        for (int i = 0; i < n; i++) {
            int space = lines.get(i).indexOf(' ');
            tables[i] = lines.get(i).substring(0, space);
            keys[i] = lines.get(i).substring(space + 1);
        }

        Lookup lookup;
        switch (lib) {
            case "tomlj" -> {
                TomlParseResult root = Toml.parse(text);
                if (root.hasErrors())
                    fail(root.errors().get(0).toString());
                List<List<String>> tablePaths = new ArrayList<>(), keyPaths = new ArrayList<>();
                for (int i = 0; i < n; i++) {
                    tablePaths.add(List.of(tables[i]));
                    keyPaths.add(List.of(keys[i]));
                }
                lookup = i -> {
                    org.tomlj.TomlTable t = root.getTable(tablePaths.get(i));
                    return t == null ? null : t.getLong(keyPaths.get(i));
                };
            }
            case "jtoml" -> {
                TomlDocument root = JToml.jToml().readFromString(text);
                TomlKey[] tableKeys = new TomlKey[n], valueKeys = new TomlKey[n];
                for (int i = 0; i < n; i++) {
                    tableKeys[i] = TomlKey.literal(tables[i]);
                    valueKeys[i] = TomlKey.literal(keys[i]);
                }
                lookup = i -> {
                    TomlValue t = root.get(tableKeys[i]);
                    if (t == null || !t.isTable())
                        return null;
                    TomlValue v = t.asTable().get(valueKeys[i]);
                    return v != null && v.isPrimitive() ? v.asPrimitive().asLong() : null;
                };
            }
            default -> throw new IllegalArgumentException("unknown library " + lib);
        }

        long[] result = new long[2]; // sum, missing
        Measurement m = measure(minSamples, () -> {
            long sum = 0, missing = 0;
            for (int i = 0; i < n; i++) {
                Long v = lookup.get(i);
                if (v != null)
                    sum += v;
                else
                    missing++;
            }
            result[0] = sum;
            result[1] = missing;
        });
        System.out.printf("%.1f ns/lookup, %d lookups, sum %d, missing %d (n=%d, %s)%n",
            m.medianNs() / n, n, result[0], result[1], m.samples(), m.status());
    }

    static void fail(String message) {
        System.err.println("parse error: " + message);
        System.exit(1);
    }

    public static void main(String[] args) throws Exception {
        if (args.length >= 5 && args[0].equals("lookup")) {
            lookupBench(args);
            return;
        }
        if (args.length < 3) {
            System.err.println("usage: tomlbench <tomlj|jtoml> <file> <min-samples>");
            System.exit(2);
        }
        String mode = args[0];
        byte[] bytes = Files.readAllBytes(Path.of(args[1]));
        String text = new String(bytes, StandardCharsets.UTF_8);
        int minSamples = Integer.parseInt(args[2]);
        JToml jtoml = JToml.jToml();

        Runnable parse = switch (mode) {
            case "tomlj" -> () -> {
                TomlParseResult result = Toml.parse(text);
                if (result.hasErrors())
                    throw new IllegalStateException(result.errors().get(0).toString());
                sink = result;
            };
            case "jtoml" -> () -> sink = jtoml.readFromString(text);
            default -> throw new IllegalArgumentException("unknown mode " + mode);
        };

        try {
            parse.run();
        } catch (RuntimeException e) {
            fail(e.getMessage());
        }
        Measurement m = measure(minSamples, parse);
        double ms = m.medianNs() / 1e6;
        System.out.printf("%.3f ms/op %.1f MB/s (n=%d, %s)%n", ms, bytes.length / 1048576.0 / (ms / 1000.0),
            m.samples(), m.status());
    }
}
