#!/usr/bin/env python3
"""Draws docs/benchmark.svg from results.md (the Markdown table run.sh prints).

    ./run.sh > results.md && ./plot.py

Two panels: every library's throughput on the config-like `mixed` input, and TomlBeef's speed
relative to the fastest other library on each input. Plain SVG with its own light/dark colours
(prefers-color-scheme), so it renders crisply on GitHub in either theme. No dependencies.
"""
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
DISPLAY = {"TomlBeef preserve": "TomlBeef", "Tomlyn syntax": "Tomlyn (syntax tree)",
           "BurntSushi": "BurntSushi/toml", "toml (Rust)": "toml"}
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


def throughput_panel(parsers, results, top):
    """Horizontal bars: MB/s on the mixed input, grouped into data model and style-preserving."""
    out = []
    label_w, bar_x, bar_w = 190, 200, 560
    row_h, bar_h = 25, 16
    y = top
    out.append(text(40, y, "Parsing a 3.9 MB config file", "title"))
    y += 22
    out.append(text(40, y, "MB/s, higher is better · each library into its own document type", "subtitle"))
    y += 18
    peak = max(v for v in results.values() if v is not None)
    for group, members in (("Data model", [p for p in parsers if p not in PRESERVING]),
                           ("Keeps comments and formatting", [p for p in parsers if p in PRESERVING])):
        y += 22
        out.append(text(40, y, group.upper(), "group"))
        y += 8
        ordered = sorted(members, key=lambda p: -(results[p] or -1))
        for p in ordered:
            v = results[p]
            cy = y + row_h / 2
            ours = p.startswith("TomlBeef")
            name = DISPLAY.get(p, p)
            out.append(text(40, cy + 5, LANGUAGE[p], "lang"))
            out.append(text(bar_x - 10, cy + 5, name, "label ours" if ours else "label", "end"))
            if v is None:
                out.append(text(bar_x + 4, cy + 5, "n/a: no date/time in schema-less mode", "note"))
            else:
                w = max(2.0, bar_w * v / peak)
                out.append(f'<rect x="{bar_x}" y="{cy - bar_h / 2:.1f}" width="{w:.1f}" height="{bar_h}" rx="3" class="{"bar-ours" if ours else "bar"}"/>')
                out.append(text(bar_x + w + 8, cy + 5, f"{v:.1f}" if v < 100 else f"{v:.0f}", "value ours" if ours else "value"))
            y += row_h
    return out, y


def speedup_panel(parsers, table, top):
    """Per input: TomlBeef's MB/s over the fastest other library, plain and style-preserving."""
    out = []
    bar_x, bar_w = 200, 470
    y = top
    out.append(text(40, y, "Speed relative to the fastest other library", "title"))
    y += 22
    out.append(text(40, y, "per input shape · 1× = as fast as the fastest other library that parsed it", "subtitle"))
    y += 30
    rows = []
    for name, results in table.items():
        plain_rivals = {p: v for p, v in results.items() if p not in PRESERVING and p != "TomlBeef" and v}
        pres_rivals = {p: v for p, v in results.items() if p in PRESERVING and p != "TomlBeef preserve" and v}
        bp = max(plain_rivals, key=plain_rivals.get)
        bs = max(pres_rivals, key=pres_rivals.get)
        rows.append((name, results["TomlBeef"] / plain_rivals[bp], bp,
                     results["TomlBeef preserve"] / pres_rivals[bs], bs))
    peak = max(max(r[1], r[3]) for r in rows)
    scale = lambda ratio: bar_w * ratio / peak
    # Legend
    out.append(f'<rect x="{bar_x}" y="{y - 11}" width="12" height="12" rx="2" class="bar-ours"/>')
    out.append(text(bar_x + 18, y, "data model", "legend"))
    out.append(f'<rect x="{bar_x + 120}" y="{y - 11}" width="12" height="12" rx="2" class="bar-ours-alt"/>')
    out.append(text(bar_x + 138, y, "keeps comments and formatting", "legend"))
    y += 16
    grid_top = y
    for name, rp, bp, rs, bs in rows:
        out.append(text(bar_x - 10, y + 20, INPUT_LABELS.get(name, name), "label", "end"))
        for i, (ratio, rival, cls) in enumerate(((rp, bp, "bar-ours"), (rs, bs, "bar-ours-alt"))):
            by = y + 5 + i * 15
            w = scale(ratio)
            out.append(f'<rect x="{bar_x}" y="{by:.1f}" width="{w:.1f}" height="12" rx="2" class="{cls}"/>')
            rival_name = "toml (Rust)" if rival == "toml (Rust)" else DISPLAY.get(rival, rival)
            out.append(text(bar_x + w + 8, by + 10.5, f"{ratio:.1f}×  vs {rival_name}", "small"))
        y += 40
    # 1× reference line
    x1 = bar_x + scale(1.0)
    out.insert(0, f'<line x1="{x1:.1f}" y1="{grid_top}" x2="{x1:.1f}" y2="{y}" class="ref"/>')
    out.append(text(x1, y + 14, "1×", "axis", "middle"))
    return out, y + 20


def main():
    header, table = read_results()
    panel1, y = throughput_panel(header, table["mixed"], 44)
    panel2, y = speedup_panel(header, table, y + 56)
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
    .small, .legend {{ font-size: 12px; fill: #424a53; }}
    .note {{ font-size: 12px; font-style: italic; fill: #8c959f; }}
    .bar {{ fill: #afb8c1; }}
    .bar-ours {{ fill: #ea580c; }}
    .bar-ours-alt {{ fill: #fb923c; }}
    .ref {{ stroke: #8c959f; stroke-width: 1; stroke-dasharray: 3 3; }}
    @media (prefers-color-scheme: dark) {{
      .bg {{ fill: #0d1117; }}
      .title, .label {{ fill: #e6edf3; }}
      .subtitle, .footer, .axis, .group {{ fill: #8d96a0; }}
      .lang, .note {{ fill: #6e7681; }}
      .value, .small, .legend {{ fill: #c9d1d9; }}
      .value.ours {{ fill: #fb923c; }}
      .bar {{ fill: #3d444d; }}
      .bar-ours {{ fill: #f97316; }}
      .bar-ours-alt {{ fill: #fdba74; }}
      .ref {{ stroke: #6e7681; }}
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
