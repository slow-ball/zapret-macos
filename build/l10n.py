#!/usr/bin/env python3
"""The app's languages: build/l10n.py <Resources folder>.
Russian is the source language, its strings are right in the code. English is the dictionary
app/l10n/en.py, which becomes en.lproj/Localizable.strings. ru.lproj is empty: so macOS knows Russian is there.
With --check <.stringsdata folder>: every Russian string of the code has a translation, and every
translation still has its string in the code."""

import json
import pathlib
import re
import runpy
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
EN = runpy.run_path(str(ROOT / "app" / "l10n" / "en.py"))["EN"]


def quote(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n") + '"'


def write(resources):
    for lang, table in (("en", EN), ("ru", {})):
        d = pathlib.Path(resources) / f"{lang}.lproj"
        d.mkdir(parents=True, exist_ok=True)
        lines = [f"{quote(k)} = {quote(v)};" for k, v in sorted(table.items())]
        (d / "Localizable.strings").write_text("\n".join(lines) + "\n", encoding="utf-16")


def check(folder):
    keys = set()
    for f in pathlib.Path(folder).glob("*.stringsdata"):
        for table in json.loads(f.read_text())["tables"].values():
            keys.update(e["key"] for e in table if re.search("[А-Яа-яЁё]", e["key"]))
    missing = sorted(k for k in keys if k not in EN)
    unused = sorted(k for k in EN if k not in keys)
    for k in missing:
        print("нет перевода:", k)
    for k in unused:
        print("перевод без строки в коде:", k)
    return not missing and not unused


if __name__ == "__main__":
    if sys.argv[1] == "--check":
        sys.exit(0 if check(sys.argv[2]) else 1)
    write(sys.argv[1])
