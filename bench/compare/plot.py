#!/usr/bin/env python3
"""Draws docs/benchmark.svg from results.md (the Markdown table run.sh prints).

    ./run.sh > results.md && ./plot.py

Two panels: every library's average speed relative to TomlBeef (geometric mean over all inputs),
and TomlBeef against the fastest other library on each input (a labelled pair of MB/s bars). Plain SVG with its own light/dark colours
(prefers-color-scheme), so it renders crisply on GitHub in either theme. No dependencies.
"""
import math
import os
import re

HERE = os.path.dirname(os.path.abspath(__file__))
RESULTS = os.path.join(HERE, "results.md")
OUT = os.path.join(HERE, "..", "..", "docs", "benchmark.svg")

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
# The per-cell time limit run.sh used (TIMEOUT cells count at input size / LIMIT)
LIMIT = float(os.environ.get("LIMIT", "60"))
INPUTS = os.path.join(HERE, "inputs")
INPUT_LABELS = {
    "mixed": "config (mixed)", "commented": "commented config", "comments": "comments only",
    "strings": "strings", "ints": "integers", "floats": "floats", "dates": "dates",
    "arrays": "small arrays", "headers": "[table] headers", "dotted": "dotted keys",
}

W = 920
FONT = "system-ui, -apple-system, 'Segoe UI', Helvetica, Arial, sans-serif"


def read_results():
    """Returns (parsers, table, timeouts): table[input][parser] is MB/s or None (FAIL or TIMEOUT);
    timeouts[(input, parser)] is the speed bound for a TIMEOUT cell, input size / LIMIT."""
    rows = [l for l in open(RESULTS) if l.startswith("|") and not l.startswith("|---")]
    split = lambda l: [c.strip() for c in l.strip().strip("|").split("|")]
    header = split(rows[0])[1:]
    table, timeouts = {}, {}
    for line in rows[1:]:
        cells = split(line)
        name = cells[0]
        table[name] = {p: (float(v) if re.match(r"^[0-9.]+$", v) else None) for p, v in zip(header, cells[1:])}
        for p, v in zip(header, cells[1:]):
            if v == "TIMEOUT":
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
    the fastest input dominate. A timed-out input counts at its speed bound, which favours that
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
    """Per input: TomlBeef against the fastest other library, as a pair of labelled MB/s bars, once
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


def main():
    header, table, timeouts = read_results()
    panel1, y = relative_panel(header, table, timeouts, 44)
    panel2, y = head_to_head_panel(header, table, timeouts, y + 56)
    height = y + 56
    footer = [
        text(40, height - 34, "Validation differs: zig-toml accepts invalid TOML (duplicate keys, invalid dates, control "
             "characters, bad UTF-8); glaze and toml-c skip UTF-8 checks.", "footer"),
        text(40, height - 16, "Linux x86-64, single thread · bench/compare (pinned versions, generated inputs) · "
             "Java, C# and JavaScript warm up for 1 s first", "footer"),
    ]
    style = f"""
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
    }}
  </style>"""
    svg = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{height}" viewBox="0 0 {W} {height}" role="img" '
           f'aria-label="TomlBeef parsing throughput compared with other TOML libraries">', style,
           f'<rect class="bg" x="0" y="0" width="{W}" height="{height}" rx="10"/>']
    svg += panel1 + panel2 + footer + ["</svg>"]
    with open(OUT, "w") as f:
        f.write("\n".join(svg) + "\n")
    print(f"wrote {os.path.relpath(OUT)}")


if __name__ == "__main__":
    main()
