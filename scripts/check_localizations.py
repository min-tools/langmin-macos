#!/usr/bin/env python3
"""Check translation keys against localized() calls in Swift sources.

Report missing and unused keys, and fail on missing keys, conflicting
English fallbacks, or incompatible format arguments. Fallbacks stay inline.
Run: python3 scripts/check_localizations.py
"""

import glob
import json
import re
import subprocess
import sys

from source_files import ROOT

SOURCES = [str(path) for path in sorted((ROOT / "langmin/Sources").rglob("*.swift"))]


CALL = re.compile(r'localized\(\s*"([a-z0-9_]+)",\s*"((?:[^"\\]|\\.)*)"\s*\)')
FORMAT = re.compile(r'%%|%(?:(\d+)\$)?[-+ #0]*\d*(?:\.\d+)?(hh|ll|h|l|q|z|t|j)?([@diuoxXfFeEgGaAcCsSp])')

def format_arguments(text):
    """format_arguments(text): Map argument positions to types; translations may reorder numbered arguments."""
    arguments = {}
    numbered = set()
    next_position = 1
    # Extract printf-style arguments while retaining their explicit or implicit positions.
    for match in FORMAT.finditer(text):
        # An escaped percent sign consumes no format argument.
        if match[0] == "%%":
            continue
        numbered.add(match[1] is not None)
        position = int(match[1]) if match[1] else next_position
        kind = (match[2] or "") + match[3]
        # A repeated argument must keep its type; mixed numbering is ambiguous.
        if position < 1 or (position in arguments and arguments[position] != kind):
            raise ValueError("conflicting format arguments")
        arguments[position] = kind
        next_position += 1
    # Reject mixed argument numbering because its positions are ambiguous.
    if len(numbered) > 1:
        raise ValueError("mixed numbered and unnumbered arguments")
    return arguments

# source_keys(): Collect inline English fallbacks and detect keys reused with
# different text.
def source_keys():
    ids = {}
    conflicts = []
    # Read every source file in the app source inventory.
    for path in SOURCES:
        # Tolerate a source that disappears while the inventory is being scanned.
        try:
            text = open(path, encoding="utf-8").read()
        # Skip a removed source file and continue checking the remaining inventory.
        except FileNotFoundError:
            continue
        # Record each recognized localization call and its English fallback.
        for match in CALL.finditer(text):
            sid, english = match.group(1), match.group(2)
            # The same key must not describe two different English strings.
            if sid in ids and ids[sid] != english:
                conflicts.append(sid)
            ids[sid] = english
    return ids, conflicts

# strings_values(path): Use macOS plist parsing to read .strings files with
# their normal escaping rules.
def strings_values(path):
    out = subprocess.run(
        ["plutil", "-convert", "json", "-o", "-", path],
        capture_output=True, check=True,
    )
    return json.loads(out.stdout)

# main(): Report key coverage and argument compatibility for every translation.
def main():
    ids, conflicts = source_keys()
    print(f"{len(ids)} keys in source")
    failed = False
    # Conflicting English definitions make localization validation fail.
    if conflicts:
        failed = True
        print(f"  CONFLICT: ids reused with different English text: {sorted(set(conflicts))}")
    expected = set(ids)
    # Check each language bundle in a stable order.
    for path in sorted(glob.glob(str(ROOT / "langmin/Resources/*.lproj/Localizable.strings"))):
        lang = path.split("/")[-2].removesuffix(".lproj")
        # English has inline fallbacks and does not require a complete resource table.
        if lang == "en":
            continue  # Partial English resource entries are allowed.
        values = strings_values(path)
        have = set(values)
        missing = expected - have
        extra = have - expected
        status = []
        # Missing translated keys fail validation and identify the English fallback behavior.
        if missing:
            failed = True
            status.append(f"{len(missing)} missing (falls back to English): "
                          + "; ".join(sorted(missing)[:5]))
        # Report unused keys without failing to allow translations to be cleaned up separately.
        if extra:
            status.append(f"{len(extra)} unused in this source set: " + "; ".join(sorted(extra)[:5]))
        # Wrong argument types can crash String(format:), not just mistranslate it.
        bad_formats = []
        # Compare format signatures for keys present in both source and translation.
        for sid in sorted(expected & have):
            # Treat malformed format syntax as an incompatible translation.
            try:
                matches = format_arguments(ids[sid]) == format_arguments(values[sid])
            # An invalid format signature cannot safely match the source.
            except ValueError:
                matches = False
            # Collect mismatches so the report includes every affected key.
            if not matches:
                bad_formats.append(sid)
        # Incompatible format arguments are validation failures, not merely missing translations.
        if bad_formats:
            failed = True
            status.append("incompatible format arguments: " + "; ".join(bad_formats))
        print(f"  {lang}: " + ("; ".join(status) if status else "complete"))
    sys.exit(1 if failed else 0)

# Run the checker only when invoked as a command.
if __name__ == "__main__":
    main()
