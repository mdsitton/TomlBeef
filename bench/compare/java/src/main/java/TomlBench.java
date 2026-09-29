// Java TOML benchmark: tomlbench <tomlj|jtoml> <file> <iterations>
// Reads the file once, warms up for 1 s (at least one parse) so the JIT has compiled the parser,
// then times up to <iterations> parses within a 3 s budget.
//   tomlj - org.tomlj.Toml.parse (TomlParseResult; errors are collected, not thrown)
//   jtoml - JToml.readFromString (TomlDocument, which also keeps comments)
import io.github.wasabithumb.jtoml.JToml;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import org.tomlj.Toml;
import org.tomlj.TomlParseResult;

public final class TomlBench {
    static volatile Object sink;

    public static void main(String[] args) throws Exception {
        if (args.length < 3) {
            System.err.println("usage: tomlbench <tomlj|jtoml> <file> <iterations>");
            System.exit(2);
        }
        String mode = args[0];
        byte[] bytes = Files.readAllBytes(Path.of(args[1]));
        String text = new String(bytes, StandardCharsets.UTF_8);
        int iterations = Integer.parseInt(args[2]);
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
            long warmStart = System.nanoTime();
            do {
                parse.run();
            } while (System.nanoTime() - warmStart < 1_000_000_000L);
        } catch (RuntimeException e) {
            System.err.println("parse error: " + e.getMessage());
            System.exit(1);
        }

        // Stop after <iterations> parses or 3 s, whichever comes first (at least one)
        long start = System.nanoTime();
        int done = 0;
        while (done < iterations && (done == 0 || System.nanoTime() - start < 3_000_000_000L)) {
            parse.run();
            done++;
        }
        double ms = (System.nanoTime() - start) / 1e6 / done;
        System.out.printf("%.3f ms/op %.1f MB/s%n", ms, bytes.length / 1048576.0 / (ms / 1000.0));
    }
}
