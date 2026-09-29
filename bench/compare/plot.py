#!/usr/bin/env python3
"""Draws docs/benchmark.svg (chart) and docs/benchmark-table.svg (full results table) from results.md
(the Markdown table run.sh prints) and lookup-results.md, and docs/benchmark-beef.svg (TomlBeef against
Beef's StructuredData) from beef-results.md (beef.sh).

    ./run.sh > results.md && ./plot.py

Two panels: every library's average speed relative to TomlBeef (geometric mean over all inputs),
and TomlBeef against the fastest other library on each input (a labeled pair of MB/s bars). Plain SVG with its own light/dark colors
(prefers-color-scheme), so it renders crisply on GitHub in either theme. No dependencies.
"""
import math
import os
import re

HERE = os.path.dirname(os.path.abspath(__file__))
RESULTS = os.path.join(HERE, "results.md")
OUT = os.path.join(HERE, "..", "..", "docs", "benchmark.svg")
TABLE_OUT = os.path.join(HERE, "..", "..", "docs", "benchmark-table.svg")
LOOKUP_RESULTS = os.path.join(HERE, "lookup-results.md")

# Style-preserving parsers (keep comments and formatting) are compared with each other
PRESERVING = {"TomlBeef preserve", "toml_edit", "Tomlyn syntax"}
LANGUAGE = {
    "TomlBeef": "Beef", "tomlc17": "C", "toml-c": "C", "toml11": "C++", "toml++": "C++",
    "glaze": "C++", "toml (Rust)": "Rust", "toml-spanner": "Rust", "toml-span": "Rust",
    "zig-toml": "Zig", "BurntSushi": "Go", "go-toml": "Go", "tomlj": "Java", "jtoml": "Java",
    "Tomlyn": "C#", "js-toml": "JS", "smol-toml": "JS", "toml (JS)": "JS",
    "TomlBeef preserve": "Beef", "toml_edit": "Rust", "Tomlyn syntax": "C#",
}
# Names in the average panel, where the repository beside each one tells same-named libraries apart
DISPLAY = {"TomlBeef preserve": "TomlBeef", "Tomlyn syntax": "Tomlyn (syntax tree)",
           "BurntSushi": "toml", "toml (Rust)": "toml", "toml (JS)": "toml"}
# Names in the per-input panel, which has no repository column
SHORT = {"TomlBeef preserve": "TomlBeef", "Tomlyn syntax": "Tomlyn (syntax tree)",
         "BurntSushi": "BurntSushi/toml", "toml (Rust)": "toml (Rust)", "toml (JS)": "toml (JS)"}
REPO = {
    "TomlBeef": "mdsitton/TomlBeef", "TomlBeef preserve": "mdsitton/TomlBeef",
    "tomlc17": "cktan/tomlc17", "toml-c": "arp242/toml-c", "toml11": "ToruNiina/toml11",
    "toml++": "marzer/tomlplusplus", "glaze": "stephenberry/glaze",
    "toml (Rust)": "toml-rs/toml", "toml_edit": "toml-rs/toml",
    "toml-spanner": "exrok/toml-spanner", "toml-span": "EmbarkStudios/toml-span",
    "zig-toml": "sam701/zig-toml",
    "BurntSushi": "BurntSushi/toml", "go-toml": "pelletier/go-toml",
    "tomlj": "tomlj/tomlj", "jtoml": "WasabiThumb/jtoml",
    "Tomlyn": "xoofx/Tomlyn", "Tomlyn syntax": "xoofx/Tomlyn",
    "js-toml": "sunnyadn/js-toml", "smol-toml": "squirrelchat/smol-toml", "toml (JS)": "BinaryMuse/toml-node",
}
# Why a library rejects some of the (valid) inputs, for its footnote
FAIL_REASON = {"glaze": "no date/time in its schema-less mode", "toml-span": "no date/time support"}
# The per-cell time limit run.sh used (DNF cells count at input size / LIMIT)
LIMIT = float(os.environ.get("LIMIT", "60"))
INPUTS = os.path.join(HERE, "inputs")
INPUT_LABELS = {
    "mixed": "config (mixed)", "commented": "commented config", "comments": "comments only",
    "strings": "strings", "ints": "integers", "floats": "floats", "dates": "dates",
    "arrays": "small arrays", "headers": "[table] headers", "dotted": "dotted keys",
}

W = 920
TABLE_W = 1124  # the results table needs more room: ten parse columns and two lookup columns
FONT = "system-ui, -apple-system, 'Segoe UI', Helvetica, Arial, sans-serif"


def read_results():
    """Returns (parsers, table, timeouts): table[input][parser] is MB/s or None (FAIL or DNF);
    timeouts[(input, parser)] is the speed bound for a DNF cell, input size / LIMIT."""
    rows = [l for l in open(RESULTS) if l.startswith("|") and not l.startswith("|---")]
    split = lambda l: [c.strip() for c in l.strip().strip("|").split("|")]
    header = split(rows[0])[1:]
    table, timeouts = {}, {}
    for line in rows[1:]:
        cells = split(line)
        name = cells[0]
        table[name] = {p: (float(v) if re.match(r"^[0-9.]+$", v) else None) for p, v in zip(header, cells[1:])}
        for p, v in zip(header, cells[1:]):
            if v == "DNF":
                timeouts[(name, p)] = os.path.getsize(os.path.join(INPUTS, name + ".toml")) / 1048576.0 / LIMIT
    return header, table, timeouts


def esc(s):
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def text(x, y, s, cls, anchor="start"):
    return f'<text x="{x:.1f}" y="{y:.1f}" class="{cls}" text-anchor="{anchor}">{esc(s)}</text>'


def relative_speeds(parsers, table, timeouts):
    """Each library's speed relative to TomlBeef (plain parsers against plain TomlBeef, preserving
    ones against TomlBeef preserve): the geometric mean over the inputs it parsed of its MB/s divided
    by TomlBeef's. The geometric mean is the right average for ratios; an arithmetic one would let
    the fastest input dominate. A timed-out input counts at its speed bound, which favors that
    library; failed inputs are left out. Returns {parser: (ratio, inputs counted)}."""
    speeds = {}
    for p in parsers:
        base = "TomlBeef preserve" if p in PRESERVING else "TomlBeef"
        ratios = []
        for name, row in table.items():
            v = row[p] if row[p] is not None else timeouts.get((name, p))
            if v:
                ratios.append(v / row[base])
        speeds[p] = (math.exp(sum(math.log(r) for r in ratios) / len(ratios)), len(ratios))
    return speeds


def caveat(p, table, timeouts):
    """Footnote text for a library that failed or timed out on some inputs, else None."""
    failed = [INPUT_LABELS.get(i, i) for i, row in table.items() if row[p] is None and (i, p) not in timeouts]
    slow = [INPUT_LABELS.get(i, i) for i, row in table.items() if (i, p) in timeouts]
    parts = []
    if failed:
        reason = FAIL_REASON.get(p, "rejected as invalid")
        parts.append(f"failed {' and '.join(failed)} ({reason}; left out of its average)")
    if slow:
        parts.append(f"did not finish {', '.join(slow)} within {LIMIT:.0f} s (counted at that bound, "
                     "which flatters it)")
    return f"{SHORT.get(p, p)} " + "; ".join(parts) + "." if parts else None


def relative_panel(parsers, table, timeouts, top):
    """Horizontal bars: average speed relative to TomlBeef, grouped into data model and preserving."""
    out = []
    name_x, bar_x, bar_w = 80, 340, 330
    row_h, bar_h = 25, 16
    speeds = relative_speeds(parsers, table, timeouts)
    # Bars are scaled to the fastest library (1× when TomlBeef leads)
    peak = max(1.0, max(r for r, _ in speeds.values()))
    footnotes = []
    y = top
    out.append(text(40, y, "Average speed relative to TomlBeef", "title"))
    y += 22
    out.append(text(40, y, f"geometric mean over {len(table)} inputs of each library's MB/s ÷ TomlBeef's · "
                    "higher is better · TomlBeef = 1×", "subtitle"))
    y += 18
    for group, members in (("Data model", [p for p in parsers if p not in PRESERVING]),
                           ("Keeps comments and formatting", [p for p in parsers if p in PRESERVING])):
        y += 22
        out.append(text(40, y, group.upper(), "group"))
        y += 8
        for p in sorted(members, key=lambda p: -speeds[p][0]):
            ratio, parsed = speeds[p]
            cy = y + row_h / 2
            ours = p.startswith("TomlBeef")
            name = DISPLAY.get(p, p)
            # A library that failed or timed out on some inputs is starred and explained below
            note_text = caveat(p, table, timeouts)
            if note_text:
                name += "*"
                footnotes.append("* " + note_text)
            out.append(text(40, cy + 5, LANGUAGE[p], "lang"))
            out.append(f'<text x="{name_x}" y="{cy + 5:.1f}"><tspan class="{"label ours" if ours else "label"}">{esc(name)}</tspan>'
                       f'<tspan class="repo" dx="8">{esc(REPO[p])}</tspan></text>')
            w = max(2.0, bar_w * ratio / peak)
            out.append(f'<rect x="{bar_x}" y="{cy - bar_h / 2:.1f}" width="{w:.1f}" height="{bar_h}" rx="3" class="{"bar-ours" if ours else "bar"}"/>')
            shown = f"{ratio:.2f}×" if ratio >= 0.1 else f"{ratio:.3f}×"
            if ours:
                note = "baseline"
            elif ratio > 1:
                note = f"{ratio:.1f}× faster than TomlBeef"
            else:
                note = f"TomlBeef {1 / ratio:.1f}× faster"
            out.append(f'<text x="{bar_x + w + 8:.1f}" y="{cy + 5:.1f}" class="small">'
                       f'<tspan class="{"value ours" if ours else "value"}">{shown}</tspan>'
                       f'<tspan class="note-plain" dx="8">{esc(note)}</tspan></text>')
            y += row_h
    for note in footnotes:
        y += 22
        out.append(text(40, y, note, "footnote"))
    return out, y


def head_to_head_panel(parsers, table, timeouts, top):
    """Per input: TomlBeef against the fastest other library, as a pair of labeled MB/s bars, once
    for data-model parsers and once for style-preserving ones. Inputs differ by 50× in speed, so
    each input's bars are scaled to its own fastest bar."""
    out = []
    label_x = 180
    columns = ((200, "DATA MODEL", "TomlBeef", lambda p: p not in PRESERVING),
               (565, "KEEPS COMMENTS AND FORMATTING", "TomlBeef preserve", lambda p: p in PRESERVING))
    bar_w, bar_h, gap, row_h = 190, 13, 4, 46
    y = top
    out.append(text(40, y, "TomlBeef against the fastest alternative, per input", "title"))
    y += 22
    out.append(text(40, y, "MB/s · for each input, the fastest other library that parsed it · bars scaled per input", "subtitle"))
    y += 34
    for x, heading, _, _ in columns:
        out.append(text(x, y, heading, "group"))
    y += 12
    for name, results in table.items():
        out.append(f'<line x1="40" y1="{y:.1f}" x2="{W - 40}" y2="{y:.1f}" class="rule"/>')
        mid = y + row_h / 2
        # Libraries that failed this input (starred as in the panel above) are noted under its name;
        # timeouts are the slowest results, so they never hide a faster rival and are not listed
        failed = [SHORT.get(p, p) + "*" for p, v in results.items() if v is None and (name, p) not in timeouts]
        if failed:
            out.append(text(label_x, mid + 1, INPUT_LABELS.get(name, name), "label", "end"))
            out.append(text(label_x, mid + 15, ", ".join(failed) + " failed", "note-plain small", "end"))
        else:
            out.append(text(label_x, mid + 5, INPUT_LABELS.get(name, name), "label", "end"))
        for x, _, ours, member in columns:
            rivals = {p: v for p, v in results.items() if member(p) and p != ours and v}
            rival = max(rivals, key=rivals.get)
            pair = ((SHORT.get(ours, ours), results[ours], True), (SHORT.get(rival, rival), rivals[rival], False))
            peak = max(v for _, v, _ in pair)
            by = mid - bar_h - gap / 2
            for lib, v, is_ours in pair:
                w = max(2.0, bar_w * v / peak)
                out.append(f'<rect x="{x}" y="{by:.1f}" width="{w:.1f}" height="{bar_h}" rx="2" class="{"bar-ours" if is_ours else "bar"}"/>')
                value = f"{v:.1f}" if v < 100 else f"{v:.0f}"
                out.append(f'<text x="{x + w + 7:.1f}" y="{by + 11:.1f}" class="small">'
                           f'<tspan class="{"value ours" if is_ours else "value"}">{value}</tspan>'
                           f'<tspan class="{"libname ours" if is_ours else "libname"}" dx="6">{esc(lib)}</tspan></text>')
                by += bar_h + gap
        y += row_h
    out.append(f'<line x1="40" y1="{y:.1f}" x2="{W - 40}" y2="{y:.1f}" class="rule"/>')
    return out, y + 8


# Two-line column headings for the results table
INPUT_HEAD = {
    "mixed": ("config", "(mixed)"), "commented": ("commented", "config"), "comments": ("comments", "only"),
    "strings": ("strings", ""), "ints": ("integers", ""), "floats": ("floats", ""), "dates": ("dates", ""),
    "arrays": ("small", "arrays"), "headers": ("[table]", "headers"), "dotted": ("dotted", "keys"),
}


def table_panel(parsers, table, timeouts, top):
    """The full results: one row per library (grouped and ordered as in the average panel), one
    column per input, MB/s per cell. The fastest cell of each column within its group is bold, and
    every cell is shaded by its speed relative to that best (log scale)."""
    out = []
    name_x, first_col, col_w, row_h = 40, 335, 60, 30
    width = TABLE_W
    inputs = list(table.keys())
    speeds = relative_speeds(parsers, table, timeouts)
    # Key-lookup columns (lookup-results.md) after the parse columns; lower is better, and libraries
    # without a lookup harness show a dash
    lookup_libs, lookup_docs = read_lookups()
    lookup_x, lookup_w = first_col + len(inputs) * col_w + 16, 66
    lookup_heads = [("1000-key", "tables"), ("15000 root", "sections")]
    y = top
    out.append(text(40, y, "Full results", "title"))
    y += 22
    out.append(text(40, y, "Parsing: MB/s (higher is better) · key lookups: ns (lower is better) · bold = best in its "
                    "group · shading = relative to that best (log scale)", "subtitle"))
    y += 32
    out.append(text(first_col + len(inputs) * col_w / 2, y - 16, "PARSING (MB/s)", "group", "middle"))
    out.append(text(lookup_x + lookup_w, y - 16, "KEY LOOKUP (ns)", "group", "middle"))
    for c, (top_line, bottom_line) in enumerate(lookup_heads):
        cx = lookup_x + c * lookup_w + lookup_w / 2
        out.append(text(cx, y, top_line, "colhead", "middle"))
        out.append(text(cx, y + 14, bottom_line, "colhead", "middle"))
    for c, name in enumerate(inputs):
        top_line, bottom_line = INPUT_HEAD.get(name, (name, ""))
        cx = first_col + c * col_w + col_w / 2
        if bottom_line:
            out.append(text(cx, y, top_line, "colhead", "middle"))
            out.append(text(cx, y + 14, bottom_line, "colhead", "middle"))
        else:
            out.append(text(cx, y + 14, top_line, "colhead", "middle"))
    y += 20
    for group, members in (("DATA MODEL", [p for p in parsers if p not in PRESERVING]),
                           ("KEEPS COMMENTS AND FORMATTING", [p for p in parsers if p in PRESERVING])):
        y += 20
        out.append(text(name_x, y, group, "group"))
        y += 6
        best = {i: max((table[i][p] for p in members if table[i][p]), default=0) for i in inputs}
        lookup_best = [min((values[lookup_libs.index(p)] for p in members
                            if p in lookup_libs and isinstance(values[lookup_libs.index(p)], float)), default=0)
                       for _, values in lookup_docs]
        for p in sorted(members, key=lambda p: -speeds[p][0]):
            ours = p.startswith("TomlBeef")
            out.append(f'<line x1="40" y1="{y:.1f}" x2="{width - 40}" y2="{y:.1f}" class="rule"/>')
            if ours:
                out.append(f'<rect x="40" y="{y:.1f}" width="{width - 80}" height="{row_h}" class="row-ours"/>')
            mid = y + row_h / 2
            star = "*" if caveat(p, table, timeouts) else ""
            out.append(f'<text x="{name_x}" y="{mid + 4.5:.1f}"><tspan class="lang">{esc(LANGUAGE[p])}</tspan>'
                       f'<tspan x="{name_x + 40}" class="{"label ours" if ours else "label"}">{esc(DISPLAY.get(p, p) + star)}</tspan>'
                       f'<tspan class="repo" dx="7">{esc(REPO[p])}</tspan></text>')
            for c, name in enumerate(inputs):
                x = first_col + c * col_w
                v = table[name][p]
                if v is None:
                    label = "DNF" if (name, p) in timeouts else "FAIL"
                    out.append(text(x + col_w - 6, mid + 4, label, "cell-missing", "end"))
                    continue
                # Shade: 1.0 at the column's best, fading over a 100× range
                level = max(0.0, 1.0 + math.log10(v / best[name]) / 2.0)
                out.append(f'<rect x="{x + 2}" y="{y + 3:.1f}" width="{col_w - 4}" height="{row_h - 6}" rx="3" '
                           f'class="heat" fill-opacity="{0.06 + 0.34 * level:.2f}"/>')
                cls = "cell" + (" best" if v == best[name] else "") + (" ours" if ours else "")
                out.append(text(x + col_w - 7, mid + 4.5, f"{v:.1f}" if v < 100 else f"{v:.0f}", cls, "end"))
            for c, (_, values) in enumerate(lookup_docs):
                x = lookup_x + c * lookup_w
                ns = values[lookup_libs.index(p)] if p in lookup_libs else "—"
                if not isinstance(ns, float):
                    out.append(text(x + lookup_w - 8, mid + 4, ns, "cell-missing", "end"))
                    continue
                level = max(0.0, 1.0 + math.log10(lookup_best[c] / ns) / 2.0)
                out.append(f'<rect x="{x + 2}" y="{y + 3:.1f}" width="{lookup_w - 4}" height="{row_h - 6}" rx="3" '
                           f'class="heat" fill-opacity="{0.06 + 0.34 * level:.2f}"/>')
                cls = "cell" + (" best" if ns == lookup_best[c] else "") + (" ours" if ours else "")
                out.append(text(x + lookup_w - 8, mid + 4.5, f"{ns:.0f}", cls, "end"))
            y += row_h
        out.append(f'<line x1="40" y1="{y:.1f}" x2="{width - 40}" y2="{y:.1f}" class="rule"/>')
    # Divider between the parsing and lookup columns
    divider_x = lookup_x - 8
    out.insert(0, f'<line x1="{divider_x}" y1="{top + 46}" x2="{divider_x}" y2="{y}" class="rule"/>')
    y += 22
    out.append(text(40, y, f"Each value is the median of 3 processes · FAIL = could not parse the input · DNF = did not "
                    f"finish within {LIMIT:.0f} s · * see the notes under the chart", "footnote"))
    return out, y + 8


def style():
    return f"""
  <style>
    svg {{ font-family: {FONT}; }}
    .bg {{ fill: #ffffff; }}
    .title {{ font-size: 19px; font-weight: 650; fill: #1f2328; }}
    .subtitle, .footer, .axis {{ font-size: 12.5px; fill: #656d76; }}
    .group {{ font-size: 11px; font-weight: 650; letter-spacing: 0.08em; fill: #656d76; }}
    .label {{ font-size: 13.5px; fill: #1f2328; }}
    .lang {{ font-size: 11px; fill: #8c959f; }}
    .ours {{ font-weight: 700; }}
    .value {{ font-size: 12.5px; fill: #424a53; font-variant-numeric: tabular-nums; }}
    .value.ours {{ fill: #c2410c; }}
    .small {{ font-size: 12px; fill: #424a53; }}
    .note-plain {{ fill: #8c959f; }}
    .footnote {{ font-size: 12px; fill: #656d76; }}
    .repo {{ font-size: 11.5px; fill: #8c959f; font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; }}
    .bar {{ fill: #afb8c1; }}
    .bar-ours {{ fill: #ea580c; }}
    .rule {{ stroke: #d8dee4; stroke-width: 1; }}
    .libname {{ fill: #656d76; }}
    .libname.ours {{ fill: #c2410c; font-weight: 650; }}
    .colhead {{ font-size: 11px; font-weight: 600; fill: #424a53; }}
    .cell {{ font-size: 12px; fill: #424a53; font-variant-numeric: tabular-nums; }}
    .cell.best {{ font-weight: 700; fill: #1f2328; }}
    .cell.ours {{ fill: #c2410c; }}
    .cell-missing {{ font-size: 10px; fill: #8c959f; }}
    .heat {{ fill: #2da44e; }}
    .row-ours {{ fill: #ea580c; fill-opacity: 0.07; }}
    .seg-ok {{ fill: #2da44e; }}
    .seg-approx {{ fill: #d4a72c; }}
    .seg-bad {{ fill: #cf222e; }}
    .seg-err {{ fill: #afb8c1; }}
    @media (prefers-color-scheme: dark) {{
      .bg {{ fill: #0d1117; }}
      .title, .label {{ fill: #e6edf3; }}
      .subtitle, .footer, .axis, .group {{ fill: #8d96a0; }}
      .lang, .note-plain {{ fill: #6e7681; }}
      .footnote {{ fill: #8d96a0; }}
      .repo {{ fill: #6e7681; }}
      .value, .small {{ fill: #c9d1d9; }}
      .value.ours {{ fill: #fb923c; }}
      .bar {{ fill: #3d444d; }}
      .bar-ours {{ fill: #f97316; }}
      .rule {{ stroke: #262c36; }}
      .libname {{ fill: #8d96a0; }}
      .libname.ours {{ fill: #fb923c; }}
      .colhead {{ fill: #c9d1d9; }}
      .cell {{ fill: #c9d1d9; }}
      .cell.best {{ fill: #f0f6fc; }}
      .cell.ours {{ fill: #fb923c; }}
      .cell-missing {{ fill: #6e7681; }}
      .heat {{ fill: #3fb950; }}
      .row-ours {{ fill: #f97316; fill-opacity: 0.10; }}
      .seg-ok {{ fill: #3fb950; }}
      .seg-approx {{ fill: #d29922; }}
      .seg-bad {{ fill: #f85149; }}
      .seg-err {{ fill: #3d444d; }}
    }}
  </style>"""


def write_svg(path, width, height, body, label):
    svg = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" viewBox="0 0 {width} {height}" role="img" '
           f'aria-label="{esc(label)}">', style(),
           f'<rect class="bg" x="0" y="0" width="{width}" height="{height}" rx="10"/>']
    svg += body + ["</svg>"]
    with open(path, "w") as f:
        f.write("\n".join(svg) + "\n")
    print(f"wrote {os.path.relpath(path)}")


def read_lookups():
    """lookup-results.md as (libraries, [(document, [ns, or "FAIL"/"DNF", per library])])."""
    rows = [l for l in open(LOOKUP_RESULTS) if l.startswith("|") and not l.startswith("|---")]
    split = lambda l: [c.strip() for c in l.strip().strip("|").split("|")]
    libs = split(rows[0])[1:]
    number = lambda v: float(v) if re.match(r"^[0-9.]+$", v) else v
    return libs, [(cells[0], [number(v) for v in cells[1:]]) for cells in map(split, rows[1:])]


def lookup_panel(top):
    """Key lookups after parsing (lookup-results.md, written by lookup.sh): ns per lookup for each
    library on each document, as log-scale bars (the results span 100 to 16000 ns), each labeled with
    its time and how it compares with TomlBeef."""
    libs, docs = read_lookups()
    out = []
    # One column per document; each lists every library, fastest first
    col_w, name_w, bar_w, row_h, bar_h = (W - 80) // 2, 150, 150, 18, 12
    numbers = [v for _, values in docs for v in values if isinstance(v, float)]
    lo, hi = math.log10(min(numbers) * 0.8), math.log10(max(numbers) * 1.1)
    scale = lambda ns: bar_w * (math.log10(ns) - lo) / (hi - lo)
    y = top
    out.append(text(40, y, "Key lookups after parsing", "title"))
    y += 22
    out.append(text(40, y, "ns per root[table][key] lookup, lower is better · 100,000 random lookups · log scale · "
                    "every library found the same values", "subtitle"))
    y += 30
    bottom = y
    for c, (doc, values) in enumerate(docs):
        x0 = 40 + c * (col_w + 20)
        out.append(text(x0, y, doc, "label"))
        by = y + 12
        base = values[libs.index("TomlBeef")]
        rank = lambda item: (0, item[1]) if isinstance(item[1], float) else (1, 0)
        for lib, ns in sorted(zip(libs, values), key=rank):
            ours = lib.startswith("TomlBeef")
            name = SHORT.get(lib, lib) + (" (preserve)" if lib == "TomlBeef preserve" else "")
            out.append(text(x0 + name_w - 8, by + 10, name, "libname ours" if ours else "libname", "end"))
            bar_x = x0 + name_w
            if not isinstance(ns, float):
                out.append(text(bar_x + 2, by + 10, ns, "cell-missing"))
            else:
                w = max(2.0, scale(ns))
                out.append(f'<rect x="{bar_x}" y="{by:.1f}" width="{w:.1f}" height="{bar_h}" rx="2" '
                           f'class="{"bar-ours" if ours else "bar"}"/>')
                compare = "" if lib == "TomlBeef" else (f"{ns / base:.1f}× slower" if ns > base * 1.05
                                                         else f"{base / ns:.1f}× faster" if ns < base / 1.05 else "≈")
                out.append(f'<text x="{bar_x + w + 6:.1f}" y="{by + 10:.1f}" class="small">'
                           f'<tspan class="{"value ours" if ours else "value"}">{ns:.0f}</tspan>'
                           f'<tspan class="note-plain" dx="6">{compare}</tspan></text>')
            by += row_h
        bottom = max(bottom, by)
    y = bottom + 10
    out.append(text(40, y, "Lookups that scan a table's entries grow with table size: toml-spanner, tomlc17, toml-c and "
                    "Tomlyn's syntax tree (which has no lookup API).", "footnote"))
    y += 18
    out.append(text(40, y, "FAIL = could not parse the document (no date/time support) · DNF = parse plus lookups "
                    f"did not finish within {LIMIT:.0f} s", "footnote"))
    return out, y + 8


BEEF_RESULTS = os.path.join(HERE, "beef-results.md")
BEEF_OUT = os.path.join(HERE, "..", "..", "docs", "benchmark-beef.svg")


def read_beef_results():
    """beef-results.md (written by beef.sh) as (checks, parse rows, lookup rows, write rows).
    checks[name] = dict of the counts in its check summary line."""
    text = open(BEEF_RESULTS).read()
    checks = {}
    pattern = (r"^(beef-projects|toml-test valid|toml-test invalid): (\d+) files: (\d+) exact match, (\d+) match except.*?, "
               r"(\d+) values differ, (\d+) StructuredData error only, (\d+) TomlBeef error only, (\d+) both reject")
    for m in re.finditer(pattern, text, re.M):
        keys = ("files", "exact", "approx", "differ", "sd_error", "tb_error", "both_reject")
        checks[m.group(1)] = dict(zip(keys, map(int, m.groups()[1:])))
    sections = {}
    current = None
    for line in text.splitlines():
        if line.startswith("### "):
            current = line[4:]
            sections[current] = []
        elif current and line.startswith("|") and not line.startswith("|---"):
            sections[current].append([c.strip() for c in line.strip().strip("|").split("|")])
    get = lambda prefix: next(rows[1:] for title, rows in sections.items() if title.startswith(prefix))
    return checks, get("Parsing"), get("Key lookups"), get("Writing")


def pair_rows(out, rows, y, label_x, bar_x, bar_w, lower_is_better):
    """Draws (label, note, StructuredData value, TomlBeef value, unit) rows as a pair of bars each,
    scaled per row, and returns the new y."""
    bar_h, gap, row_h = 13, 4, 46
    for label, note, sd, tb, unit in rows:
        out.append(f'<line x1="40" y1="{y:.1f}" x2="{W - 40}" y2="{y:.1f}" class="rule"/>')
        mid = y + row_h / 2
        if note:
            out.append(text(label_x, mid + 1, label, "label", "end"))
            out.append(text(label_x, mid + 15, note, "note-plain small", "end"))
        else:
            out.append(text(label_x, mid + 5, label, "label", "end"))
        peak = max(sd, tb)
        by = mid - bar_h - gap / 2
        for lib, v, ours in (("TomlBeef", tb, True), ("StructuredData", sd, False)):
            w = max(2.0, bar_w * v / peak)
            out.append(f'<rect x="{bar_x}" y="{by:.1f}" width="{w:.1f}" height="{bar_h}" rx="2" class="{"bar-ours" if ours else "bar"}"/>')
            better = (v < min(sd, tb) * 1.0001) if lower_is_better else (v > max(sd, tb) * 0.9999)
            ratio = max(sd, tb) / min(sd, tb)
            win = f"{ratio:.1f}× {'faster' if ratio >= 1.05 else ''}".strip() if better and ratio >= 1.05 else ""
            value = f"{v:.0f}" if v >= 100 else f"{v:.1f}"
            out.append(f'<text x="{bar_x + w + 7:.1f}" y="{by + 11:.1f}" class="small">'
                       f'<tspan class="{"value ours" if ours else "value"}">{value} {unit}</tspan>'
                       f'<tspan class="{"libname ours" if ours else "libname"}" dx="6">{lib}</tspan>'
                       f'<tspan class="note-plain" dx="8">{win}</tspan></text>')
            by += bar_h + gap
        y += row_h
    out.append(f'<line x1="40" y1="{y:.1f}" x2="{W - 40}" y2="{y:.1f}" class="rule"/>')
    return y


def beef_panels(top):
    """TomlBeef against Beef's built-in reader: correctness, parsing, lookups and writing."""
    checks, parse_rows, lookup_rows, write_rows = read_beef_results()
    out = []
    y = top
    out.append(text(40, y, "TomlBeef and Beef's built-in TOML reader", "title"))
    y += 22
    out.append(text(40, y, "Beefy.utils.StructuredData, which the Beef IDE and BeefBuild use for project files, "
                    "built into one program with TomlBeef", "subtitle"))

    # Correctness: stacked bars of file counts
    y += 40
    out.append(text(40, y, "READS TOML CORRECTLY", "group"))
    y += 14
    valid, invalid, projects = checks["toml-test valid"], checks["toml-test invalid"], checks["beef-projects"]
    invalid_total = invalid["tb_error"] + invalid["both_reject"]  # invalid under TOML 1.1 (TomlBeef rejects)
    rows = [
        ("toml-test valid files", f"{valid['files']} files",
         [("ok", valid["exact"], "read correctly"), ("approx", valid["approx"], "dates as text or float32"),
          ("bad", valid["differ"], "wrong values"), ("err", valid["sd_error"], "error")],
         [("ok", valid["files"] - valid["tb_error"] - valid["both_reject"], "read correctly")]),
        ("toml-test invalid files", f"{invalid_total} files",
         [("ok", invalid["both_reject"], "rejected"), ("bad", invalid["tb_error"], "accepted")],
         [("ok", invalid_total, "rejected")]),
        ("real Beef project files", f"{projects['files']} files",
         [("ok", projects["exact"], "read identically"), ("bad", projects["tb_error"], "invalid file accepted")],
         [("ok", projects["exact"], "read identically"), ("ok", projects["tb_error"], "invalid file rejected")]),
    ]
    bar_x, bar_w, bar_h = 200, 420, 14
    for label, sub, sd_parts, tb_parts in rows:
        out.append(f'<line x1="40" y1="{y:.1f}" x2="{W - 40}" y2="{y:.1f}" class="rule"/>')
        out.append(text(180, y + 22, label, "label", "end"))
        out.append(text(180, y + 37, sub, "note-plain small", "end"))
        total = sum(n for _, n, _ in tb_parts)
        by = y + 9
        for lib, parts, ours in (("TomlBeef", tb_parts, True), ("StructuredData", sd_parts, False)):
            x = bar_x
            for cls, n, _ in parts:
                w = bar_w * n / total
                if w > 0:
                    out.append(f'<rect x="{x:.1f}" y="{by:.1f}" width="{w:.1f}" height="{bar_h}" class="seg-{cls}"/>')
                x += w
            summary = " · ".join(f"{n} {what}" for _, n, what in parts if n)
            out.append(f'<text x="{bar_x + bar_w + 8}" y="{by + 11:.1f}" class="small">'
                       f'<tspan class="{"libname ours" if ours else "libname"}">{lib}</tspan></text>')
            out.append(text(bar_x, by + bar_h + 12, summary, "note-plain small"))
            by += bar_h + 17
        y += 76
    out.append(f'<line x1="40" y1="{y:.1f}" x2="{W - 40}" y2="{y:.1f}" class="rule"/>')
    y += 18
    out.append(text(40, y, "StructuredData has no dotted keys, literal or multi-line strings; keeps dates as text, "
                    "floats as 32-bit; does not check duplicate keys or UTF-8.", "footnote"))
    y += 18
    out.append(text(40, y, "Parsing rows marked \"not like-for-like\": StructuredData parses floats as float32 and "
                    "leaves dates unparsed, so it does less work there.", "footnote"))

    # Parsing, lookups, writing: pairs of bars
    y += 40
    out.append(text(40, y, "PARSING · MB/s, higher is better · bars scaled per row", "group"))
    y += 12
    parse = []
    for cells in parse_rows:
        name, sd, tb, like = cells[0], float(cells[1]), float(cells[2]), cells[4]
        note = "" if like.startswith("yes") else "not like-for-like"
        if name == "Beef project files":
            note = "133 BeefProj/BeefSpace files"
        parse.append((name, note, sd, tb, "MB/s"))
    y = pair_rows(out, parse, y, 180, 200, 300, False)

    y += 34
    out.append(text(40, y, "KEY LOOKUP · ns per lookup, lower is better · StructuredData Open + TryGet (a linear "
                    "scan), TomlBeef a hash map", "group"))
    y += 12
    lookups = [(cells[0].split(" × ")[0], "× " + cells[0].split(" × ")[1], float(cells[1]), float(cells[2]), "ns")
               for cells in lookup_rows]
    y = pair_rows(out, lookups, y, 180, 200, 300, True)

    y += 34
    out.append(text(40, y, "WRITING · MB/s of output, higher is better", "group"))
    y += 12
    writes = [(cells[0], "", float(cells[1]), float(cells[2]), "MB/s") for cells in write_rows]
    y = pair_rows(out, writes, y, 180, 200, 300, False)
    return out, y


def main():
    header, table, timeouts = read_results()
    panel1, y = relative_panel(header, table, timeouts, 44)
    panel2, y = head_to_head_panel(header, table, timeouts, y + 56)
    panel3, y = lookup_panel(y + 56)
    panel2 += panel3
    height = y + 56
    footer = [
        text(40, height - 34, "Validation differs: zig-toml accepts invalid TOML (duplicate keys, invalid dates, control "
             "characters, bad UTF-8); glaze and toml-c skip UTF-8 checks.", "footer"),
        text(40, height - 16, "Linux x86-64, single thread · 1 s warm-up, then samples until 60% are within ±10% "
             "of their median · median of 3 processes · bench/compare", "footer"),
    ]
    write_svg(OUT, W, height, panel1 + panel2 + footer, "TomlBeef parsing throughput compared with other TOML libraries")

    body, y = table_panel(header, table, timeouts, 44)
    write_svg(TABLE_OUT, TABLE_W, y + 24, body, "Full TOML parsing benchmark results: MB/s per library and input")

    if os.path.exists(BEEF_RESULTS):
        body, y = beef_panels(44)
        height = y + 50
        body.append(text(40, height - 16, "Same compiler and Release settings · 1 s warm-up, samples until 60% are "
                         "within ±10% of their median · median of 3 processes · beef.sh", "footer"))
        write_svg(BEEF_OUT, W, height, body, "TomlBeef compared with Beef's built-in TOML reader")


if __name__ == "__main__":
    main()
