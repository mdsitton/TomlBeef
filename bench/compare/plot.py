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
    "glaze": "C++", "toml (Rust)": "Rust", "BurntSushi": "Go", "go-toml": "Go", "Tomlyn": "C#",
    "TomlBeef preserve": "Beef", "toml_edit": "Rust", "Tomlyn syntax": "C#",
}
# Names in the average panel, where the repository beside each one tells same-named libraries apart
DISPLAY = {"TomlBeef preserve": "TomlBeef", "Tomlyn syntax": "Tomlyn (syntax tree)",
           "BurntSushi": "toml", "toml (Rust)": "toml"}
# Names in the per-input panel, which has no repository column
SHORT = {"TomlBeef preserve": "TomlBeef", "Tomlyn syntax": "Tomlyn (syntax tree)",
         "BurntSushi": "BurntSushi/toml", "toml (Rust)": "toml (Rust)"}
REPO = {
    "TomlBeef": "mdsitton/TomlBeef", "TomlBeef preserve": "mdsitton/TomlBeef",
    "tomlc17": "cktan/tomlc17", "toml-c": "arp242/toml-c", "toml11": "ToruNiina/toml11",
    "toml++": "marzer/tomlplusplus", "glaze": "stephenberry/glaze",
    "toml (Rust)": "toml-rs/toml", "toml_edit": "toml-rs/toml",
    "BurntSushi": "BurntSushi/toml", "go-toml": "pelletier/go-toml",
    "Tomlyn": "xoofx/Tomlyn", "Tomlyn syntax": "xoofx/Tomlyn",
}
INPUT_LABELS = {
    "mixed": "config (mixed)", "commented": "commented config", "comments": "comments only",
    "strings": "strings", "ints": "integers", "floats": "floats", "dates": "dates",
    "arrays": "small arrays", "headers": "[table] headers", "dotted": "dotted keys",
}

W = 920
FONT = "system-ui, -apple-system, 'Segoe UI', Helvetica, Arial, sans-serif"


def read_results():
    rows = [l for l in open(RESULTS) if l.startswith("|") and not l.startswith("|---")]
    split = lambda l: [c.strip() for c in l.strip().strip("|").split("|")]
    header = split(rows[0])[1:]
    table = {}
    for line in rows[1:]:
        cells = split(line)
        table[cells[0]] = {p: (float(v) if re.match(r"^[0-9.]+$", v) else None) for p, v in zip(header, cells[1:])}
    return header, table


def esc(s):
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def text(x, y, s, cls, anchor="start"):
    return f'<text x="{x:.1f}" y="{y:.1f}" class="{cls}" text-anchor="{anchor}">{esc(s)}</text>'


def relative_speeds(parsers, table):
    """Each library's speed relative to TomlBeef (plain parsers against plain TomlBeef, preserving
    ones against TomlBeef preserve): the geometric mean over the inputs it parsed of its MB/s divided
    by TomlBeef's. The geometric mean is the right average for ratios; an arithmetic one would let
    the fastest input dominate. Returns {parser: (ratio, inputs parsed)}."""
    speeds = {}
    for p in parsers:
        base = "TomlBeef preserve" if p in PRESERVING else "TomlBeef"
        ratios = [row[p] / row[base] for row in table.values() if row[p]]
        speeds[p] = (math.exp(sum(math.log(r) for r in ratios) / len(ratios)), len(ratios))
    return speeds


def relative_panel(parsers, table, top):
    """Horizontal bars: average speed relative to TomlBeef, grouped into data model and preserving."""
    out = []
    name_x, bar_x, bar_w = 80, 340, 360
    row_h, bar_h = 25, 16
    speeds = relative_speeds(parsers, table)
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
            # A library that failed some inputs is starred and explained in a footnote below
            failed = [INPUT_LABELS.get(i, i) for i, row in table.items() if row[p] is None]
            if failed:
                name += "*"
                footnotes.append(f"* {SHORT.get(p, p)} failed the {' and '.join(failed)} inputs "
                                 f"(no date/time support in its schema-less mode); its average covers "
                                 f"the other {parsed}.")
            out.append(text(40, cy + 5, LANGUAGE[p], "lang"))
            out.append(f'<text x="{name_x}" y="{cy + 5:.1f}"><tspan class="{"label ours" if ours else "label"}">{esc(name)}</tspan>'
                       f'<tspan class="repo" dx="8">{esc(REPO[p])}</tspan></text>')
            w = max(2.0, bar_w * ratio)
            out.append(f'<rect x="{bar_x}" y="{cy - bar_h / 2:.1f}" width="{w:.1f}" height="{bar_h}" rx="3" class="{"bar-ours" if ours else "bar"}"/>')
            shown = f"{ratio:.2f}×" if ratio >= 0.1 else f"{ratio:.3f}×"
            note = "baseline" if ours else f"TomlBeef {1 / ratio:.1f}× faster"
            out.append(f'<text x="{bar_x + w + 8:.1f}" y="{cy + 5:.1f}" class="small">'
                       f'<tspan class="{"value ours" if ours else "value"}">{shown}</tspan>'
                       f'<tspan class="note-plain" dx="8">{esc(note)}</tspan></text>')
            y += row_h
    for note in footnotes:
        y += 22
        out.append(text(40, y, note, "footnote"))
    return out, y


def head_to_head_panel(parsers, table, top):
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
        out.append(text(label_x, mid + 5, INPUT_LABELS.get(name, name), "label", "end"))
        for x, _, ours, member in columns:
            rivals = {p: v for p, v in results.items() if member(p) and p != ours and v}
            rival = max(rivals, key=rivals.get)
            pair = ((SHORT.get(ours, ours), results[ours], True), (SHORT.get(rival, rival), rivals[rival], False))
            peak = max(v for _, v, _ in pair)
            # Libraries in this group that failed this input (starred as in the panel above)
            failed = [SHORT.get(p, p) for p, v in results.items() if member(p) and v is None]
            by = mid - bar_h - gap / 2
            for lib, v, is_ours in pair:
                w = max(2.0, bar_w * v / peak)
                out.append(f'<rect x="{x}" y="{by:.1f}" width="{w:.1f}" height="{bar_h}" rx="2" class="{"bar-ours" if is_ours else "bar"}"/>')
                value = f"{v:.1f}" if v < 100 else f"{v:.0f}"
                failed_note = "" if is_ours or not failed else \
                    f'<tspan class="note-plain" dx="8">· {esc(", ".join(f + "*" for f in failed))} failed</tspan>'
                out.append(f'<text x="{x + w + 7:.1f}" y="{by + 11:.1f}" class="small">'
                           f'<tspan class="{"value ours" if is_ours else "value"}">{value}</tspan>'
                           f'<tspan class="{"libname ours" if is_ours else "libname"}" dx="6">{esc(lib)}</tspan>'
                           f'{failed_note}</text>')
                by += bar_h + gap
        y += row_h
    out.append(f'<line x1="40" y1="{y:.1f}" x2="{W - 40}" y2="{y:.1f}" class="rule"/>')
    return out, y + 8


def main():
    header, table = read_results()
    panel1, y = relative_panel(header, table, 44)
    panel2, y = head_to_head_panel(header, table, y + 56)
    height = y + 36
    footer = text(40, height - 16, "Linux x86-64, single thread · bench/compare (pinned versions, generated inputs) · "
                  "glaze and toml-c skip UTF-8 validation", "footer")
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
    svg += panel1 + panel2 + [footer, "</svg>"]
    with open(OUT, "w") as f:
        f.write("\n".join(svg) + "\n")
    print(f"wrote {os.path.relpath(OUT)}")


if __name__ == "__main__":
    main()
