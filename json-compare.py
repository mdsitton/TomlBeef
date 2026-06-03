#!/usr/bin/env python3
"""Normalize tagged JSON for semantic comparison with float tolerance.
Reads expected JSON from file (argv[1]) and actual JSON from stdin.
Exits 0 on match, 1 on mismatch, 2 on parse error.
Writes normalized expected and actual to stdout on mismatch."""

import json
import sys
import math
import re
import os


def is_float_obj(obj):
    return isinstance(obj, dict) and obj.get("type") == "float"


def is_datetime_obj(obj):
    t = obj.get("type") if isinstance(obj, dict) else None
    return t in ("datetime", "datetime-local", "time-local")


def normalize_float(val_str):
    """Normalize a float value string for comparison.
    Handles nan/inf case-insensitively, otherwise parses as float."""
    lower = val_str.lower().replace("+", "")
    if lower in ("nan", "inf", "-inf"):
        return lower
    try:
        f = float(val_str.replace("_", ""))
    except ValueError:
        return val_str
    # Use 15 significant digits to normalize representation
    return f"{f:.15g}"


def normalize_datetime(val_str):
    """Normalize datetime strings for comparison.
    Strips trailing zeros from fractional seconds."""
    # Match ISO 8601 datetime with optional fractional seconds
    m = re.match(r'^(.+?)(\.\d+?)(0*)(.*)$', val_str)
    if m:
        base = m.group(1)
        frac = m.group(2).rstrip('0')
        rest = m.group(4)
        if frac == '.':
            return base + rest
        return base + frac + rest
    return val_str


def compare_values(expected, actual, path):
    """Compare two tagged JSON values. Returns list of mismatch strings."""
    mismatches = []

    if isinstance(expected, dict) and isinstance(actual, dict):
        # Special handling for tagged values
        if is_float_obj(expected) and is_float_obj(actual):
            ev = normalize_float(expected["value"])
            av = normalize_float(actual["value"])
            if ev != av:
                # Try numeric comparison with tolerance
                try:
                    ef = float(expected["value"].replace("_", ""))
                    af = float(actual["value"].replace("_", ""))
                    if ef != af and (ef == 0 or af == 0 or abs(ef - af) / max(abs(ef), abs(af)) > 1e-12):
                        mismatches.append(f"{path}: float value mismatch: {expected['value']} vs {actual['value']}")
                except ValueError:
                    mismatches.append(f"{path}: float value mismatch: {expected['value']} vs {actual['value']}")
            return mismatches

        if is_datetime_obj(expected) and is_datetime_obj(actual):
            if expected["type"] != actual["type"]:
                mismatches.append(f"{path}: datetime type mismatch: {expected['type']} vs {actual['type']}")
                return mismatches
            ev = normalize_datetime(expected["value"])
            av = normalize_datetime(actual["value"])
            if ev != av:
                mismatches.append(f"{path}: datetime value mismatch: {expected['value']} vs {actual['value']}")
            return mismatches

        # General object comparison
        all_keys = set(expected.keys()) | set(actual.keys())
        for key in sorted(all_keys):
            if key not in expected:
                mismatches.append(f"{path}.{key}: missing in expected")
            elif key not in actual:
                mismatches.append(f"{path}.{key}: missing in actual")
            else:
                mismatches.extend(compare_values(expected[key], actual[key], f"{path}.{key}"))
        return mismatches

    elif isinstance(expected, list) and isinstance(actual, list):
        if len(expected) != len(actual):
            mismatches.append(f"{path}: array length mismatch: {len(expected)} vs {len(actual)}")
            return mismatches
        for i in range(len(expected)):
            mismatches.extend(compare_values(expected[i], actual[i], f"{path}[{i}]"))
        return mismatches

    else:
        if expected != actual:
            mismatches.append(f"{path}: value mismatch: {expected!r} vs {actual!r}")
        return mismatches


def main():
    if len(sys.argv) < 2:
        print("Usage: json-compare.py <expected.json>", file=sys.stderr)
        sys.exit(2)

    expected_path = sys.argv[1]

    try:
        with open(expected_path, 'r') as f:
            expected = json.load(f)
    except Exception as e:
        print(f"Failed to parse expected JSON: {e}", file=sys.stderr)
        sys.exit(2)

    actual_raw = sys.stdin.read()
    try:
        actual = json.loads(actual_raw)
    except Exception as e:
        print(f"Failed to parse actual JSON: {e}", file=sys.stderr)
        print("Raw actual output:", file=sys.stderr)
        print(actual_raw, file=sys.stderr)
        sys.exit(2)

    mismatches = compare_values(expected, actual, "$")
    if mismatches:
        print("MISMATCHES:")
        for m in mismatches:
            print(f"  {m}")
        # Also output normalized forms for debugging
        expected_normalized = json.dumps(expected, sort_keys=True, separators=(',', ':'))
        actual_normalized = json.dumps(actual, sort_keys=True, separators=(',', ':'))
        print("Expected (normalized):", expected_normalized, sep="\n")
        print("Actual (normalized):", actual_normalized, sep="\n")
        sys.exit(1)

    sys.exit(0)


if __name__ == "__main__":
    main()
