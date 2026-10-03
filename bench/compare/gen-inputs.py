#!/usr/bin/env python3
"""Writes the comparison benchmark inputs into inputs/ (git-ignored). Deterministic (fixed seed).

Each file is a few MB of one shape, with at most 1000 keys per table and fewer than 16384 root
entries, so every parser can read it (tomlc17 caps tables at 16384 entries).
"""
import os
import random

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "inputs")


def write(name, text):
    with open(os.path.join(OUT, name + ".toml"), "w", newline="\n") as f:
        f.write(text)
    print(f"{name:10} {len(text.encode()):>10} bytes")


def tables(count, per_table, entry):
    """`count` tables of `per_table` entries, entry(table, index) -> line."""
    parts = []
    for t in range(count):
        parts.append(f"[t{t}]\n")
        parts.extend(entry(t, i) + "\n" for i in range(per_table))
    return "".join(parts)


def mixed(rng):
    parts = ["# Synthetic benchmark input\ntitle = \"bench\"\n"]
    for s in range(15000):
        parts.append(
            f"\n# Section {s}\n[section_{s}]\n"
            f"name = \"item {s} with some text\"  # trailing comment\n"
            f"count = {rng.randrange(1000000)}\n"
            f"hex = 0x{rng.randrange(0x10000):04X}\n"
            f"ratio = {rng.random():.6f}\n"
            f"enabled = {'true' if s % 2 else 'false'}\n"
            f"when = 2024-{s % 12 + 1:02d}-{s % 28 + 1:02d}T12:30:00Z\n"
            f"tags = [\"a{s}\", \"b\", 'literal']\n"
            f"point = {{ x = {s}, y = {s * 2} }}\n"
            f"sub.dotted.key = {s}\n")
    return "".join(parts)


def commented(rng):
    """A config where most keys carry a comment above and a trailing comment, as edited by hand."""
    words = ("the quick brown fox jumps over lazy dog configure value setting enable "
             "default port host timeout").split()

    def sentence():
        return " ".join(rng.choice(words) for _ in range(rng.randint(4, 12)))

    parts = []
    for s in range(6000):
        parts.append(f"\n# {sentence()}\n# {sentence()}\n[section{s}]\n")
        for k in range(8):
            parts.append(f"# {sentence()}\nkey{k} = {rng.randrange(100000)} # {sentence()}\n")
    return "".join(parts)


def typed(rng):
    """For typed.sh: a document every typed mapper can bind (no dates, one level of nesting), a few
    root scalars and 20000 [[servers]] entries with a nested [servers.limits] table."""
    regions = ("eu", "us", "ap", "sa")
    roles = ("web", "api", "db", "cache", "queue")
    parts = ["title = \"typed benchmark\"\nversion = 3\ndebug = false\n"]
    for s in range(20000):
        tags = ", ".join(f'"{t}"' for t in (rng.choice(roles), rng.choice(regions), f"rack-{s % 40}"))
        parts.append(
            f"\n[[servers]]\n"
            f"name = \"srv-{s:06d}\"\n"
            f"host = \"10.{s // 65536 % 256}.{s // 256 % 256}.{s % 256}\"\n"
            f"port = {8000 + rng.randrange(2000)}\n"
            f"enabled = {'true' if s % 3 else 'false'}\n"
            f"weight = {rng.random():.4f}\n"
            f"tags = [{tags}]\n"
            f"\n[servers.limits]\n"
            f"max_connections = {rng.randrange(100, 10000)}\n"
            f"timeout_ms = {rng.randrange(100, 30000)}\n")
    return "".join(parts)


def main():
    os.makedirs(OUT, exist_ok=True)
    rng = random.Random(1)
    write("mixed", mixed(rng))
    write("commented", commented(rng))
    write("comments", "".join(f"# comment line {i} with some ordinary text in it to skip\n" for i in range(150000)))
    write("strings", tables(100, 1000, lambda t, i: f's{i} = "{"lorem ipsum dolor sit amet " * 3}{i}"'))
    write("ints", tables(200, 1000, lambda t, i: f"key_{i} = {rng.randrange(1000000000)}"))
    write("floats", tables(200, 1000, lambda t, i: f"f{i} = {rng.random():.9f}"))
    write("dates", tables(150, 1000, lambda t, i: f"d{i} = 2024-05-{i % 28 + 1:02d}T12:30:{i % 60:02d}Z"))
    write("arrays", tables(100, 1000, lambda t, i: f"a{i} = [1, 2, 3, 4, 5, 6, 7, 8]"))
    write("headers", "".join(f"[g{i // 500}.s{i}]\nx = {i}\n" for i in range(150000)))
    write("dotted", "".join(f"a{i % 100}.b{i}.c = {i}\n" for i in range(100000)))

    beef_projects()

    # Key lookups after parsing (lookup.sh): random `table key` pairs whose value is an integer
    lookups(rng, "ints", ((f"t{rng.randrange(200)}", f"key_{rng.randrange(1000)}") for _ in range(100000)))
    lookups(rng, "mixed", ((f"section_{rng.randrange(15000)}", "count") for _ in range(100000)))

    # Typed serialization (typed.sh); its own generator, so the inputs above stay as they were
    write("typed", typed(random.Random(2)))


def beef_projects():
    """Copies real BeefProj.toml / BeefSpace.toml files into inputs/beef-projects/ for beef.sh: from a
    Beef source checkout when BEEF_SRC names one (https://github.com/beefytech/Beef; the published
    figures used one), else from the installed Beef next to beefbuild. These are the files Beef's own
    StructuredData reader is for."""
    import shutil
    dest = os.path.join(OUT, "beef-projects")
    shutil.rmtree(dest, ignore_errors=True)
    os.makedirs(dest)
    source = os.environ.get("BEEF_SRC", "")
    if not source or not os.path.isdir(source):
        beefbuild = shutil.which("beefbuild")
        source = os.path.join(os.path.dirname(os.path.realpath(beefbuild)), "..") if beefbuild else ""
    files = []
    for root, dirs, names in os.walk(source):
        dirs[:] = sorted(d for d in dirs if not d.startswith("."))  # skip .git and tool worktrees
        files += [os.path.join(root, n) for n in sorted(names) if n in ("BeefProj.toml", "BeefSpace.toml")]
    total = 0
    for i, path in enumerate(files):
        rel = os.path.relpath(path, source).replace(os.sep, "_")
        shutil.copyfile(path, os.path.join(dest, f"{i:03d}_{rel}"))
        total += os.path.getsize(path)
    print(f"{'beef-projects':16} {len(files)} files, {total} bytes (from {os.path.realpath(source)})")


def lookups(rng, name, pairs):
    """Writes inputs/<name>.lookups: one `table key` pair per line, looked up in <name>.toml."""
    with open(os.path.join(OUT, name + ".lookups"), "w", newline="\n") as f:
        f.writelines(f"{t} {k}\n" for t, k in pairs)
    print(f"{name + '.lookups':16} 100000 lookups")


if __name__ == "__main__":
    main()
