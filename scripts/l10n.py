#!/usr/bin/env python3
"""Keep the string catalogs in App/Resources in sync with the sources.

English is the source language; Norwegian bokmål (nb) is the translation.

  Localizable.xcstrings  app strings. Keys come from the .stringsdata files the compiler
                         emits for the Varmepumpe target (SWIFT_EMIT_LOC_STRINGS), so run
                         `make debug` first.
  HeatPumpKit.xcstrings  package strings: every string literal passed directly to
                         `L10n.tr(` or `L10n.format(` under Packages/HeatPumpKit/Sources.

Commands:
  python3 scripts/l10n.py sync [--translations FILE ...] [--keep-unused]
      Add new keys, drop keys no longer in the sources (unless --keep-unused) and merge
      translations. A translations file is JSON:
        {"Localizable": {"<key>": "<nb>", ...}, "HeatPumpKit": {...}}
      A value may instead be {"nb": {"one": "...", "other": "..."},
                               "en": {"one": "...", "other": "..."}} for plural variants.
  python3 scripts/l10n.py missing [--table Localizable|HeatPumpKit] [--source PATH_PREFIX]
      List keys without a Norwegian translation (optionally only those used in PATH_PREFIX).
  python3 scripts/l10n.py check [--kit-only]
      Exit 1 if a catalog is out of sync with the sources or a key lacks a translation.
"""
import argparse
import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
RESOURCES = ROOT / "App/Resources"
KIT_SOURCES = ROOT / "Packages/HeatPumpKit/Sources"
STRINGSDATA = ROOT / "build/DerivedData/Build/Intermediates.noindex/Varmepumpe.build/Debug/Varmepumpe.build/Objects-normal/arm64"
CATALOGS = {"Localizable": RESOURCES / "Localizable.xcstrings", "HeatPumpKit": RESOURCES / "HeatPumpKit.xcstrings"}

KIT_CALL = re.compile(r'L10n\.(?:tr|format)\(\s*"((?:[^"\\\n]|\\.)*)"')
SWIFT_ESCAPES = {"n": "\n", "t": "\t", "r": "\r", '"': '"', "'": "'", "\\": "\\", "0": "\0"}


def unescape(literal, where):
    out, i = [], 0
    while i < len(literal):
        c = literal[i]
        if c != "\\":
            out.append(c)
            i += 1
            continue
        nxt = literal[i + 1]
        if nxt == "(":
            sys.exit(f"{where}: L10n key must not use interpolation; use L10n.format with %@/%lld/%.1f")
        if nxt == "u":
            end = literal.index("}", i)
            out.append(chr(int(literal[i + 3:end], 16)))
            i = end + 1
            continue
        out.append(SWIFT_ESCAPES[nxt])
        i += 2
    return "".join(out)


def kit_keys():
    """{key: [source paths]} for the package."""
    keys = {}
    for path in sorted(KIT_SOURCES.rglob("*.swift")):
        text = path.read_text(encoding="utf-8")
        for match in KIT_CALL.finditer(text):
            line = text.count("\n", 0, match.start()) + 1
            rel = path.relative_to(ROOT)
            key = unescape(match.group(1), f"{rel}:{line}")
            keys.setdefault(key, []).append(str(rel))
    return keys


def app_keys():
    """{key: [source paths]} for the app, from the compiler's .stringsdata files."""
    if not STRINGSDATA.is_dir():
        sys.exit(f"No .stringsdata in {STRINGSDATA.relative_to(ROOT)}; run `make debug` first.")
    keys = {}
    for path in sorted(STRINGSDATA.glob("*.stringsdata")):
        data = json.loads(path.read_text(encoding="utf-8"))
        source = data.get("source", "")
        if not pathlib.Path(source).exists():
            continue  # stale file from a deleted source
        try:
            rel = str(pathlib.Path(source).relative_to(ROOT))
        except ValueError:
            continue
        for table, entries in data.get("tables", {}).items():
            if table != "Localizable":
                sys.exit(f"{rel}: unexpected table {table}")
            for entry in entries:
                keys.setdefault(entry["key"], []).append(rel)
    return keys


def load(table):
    path = CATALOGS[table]
    if path.exists():
        return json.loads(path.read_text(encoding="utf-8"))
    return {"sourceLanguage": "en", "strings": {}, "version": "1.0"}


def save(table, catalog):
    text = json.dumps(catalog, indent=2, ensure_ascii=False, sort_keys=True, separators=(",", " : "))
    CATALOGS[table].write_text(text + "\n", encoding="utf-8")


def unit(value):
    return {"stringUnit": {"state": "translated", "value": value}}


def localization(value):
    if isinstance(value, str):
        return unit(value)
    return {"variations": {"plural": {form: unit(text) for form, text in value.items()}}}


def has_translation(entry):
    if entry.get("shouldTranslate") is False:
        return True
    nb = entry.get("localizations", {}).get("nb")
    if not nb:
        return False
    if "stringUnit" in nb:
        return nb["stringUnit"].get("state") == "translated" and nb["stringUnit"].get("value") != ""
    plural = nb.get("variations", {}).get("plural", {})
    return bool(plural) and all(v["stringUnit"].get("state") == "translated" for v in plural.values())


def merge(table, keys, translations, keep_unused, manual):
    catalog = load(table)
    strings = catalog.setdefault("strings", {})
    added = [k for k in keys if k not in strings]
    for key in added:
        strings[key] = {"extractionState": "manual"} if manual else {}
    removed = []
    if not keep_unused:
        removed = [k for k in strings if k not in keys]
        for key in removed:
            del strings[key]
    applied = 0
    for key, value in translations.items():
        if key not in strings:
            continue
        locs = strings[key].setdefault("localizations", {})
        if isinstance(value, dict) and ("nb" in value or "en" in value):
            for lang in ("en", "nb"):
                if lang in value:
                    locs[lang] = localization(value[lang])
        else:
            locs["nb"] = localization(value)
        applied += 1
    save(table, catalog)
    return added, removed, applied


def read_translations(files):
    merged = {"Localizable": {}, "HeatPumpKit": {}}
    for file in files or []:
        data = json.loads(pathlib.Path(file).read_text(encoding="utf-8"))
        for table in merged:
            merged[table].update(data.get(table, {}))
    return merged


def main():
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    s = sub.add_parser("sync")
    s.add_argument("--translations", nargs="*")
    s.add_argument("--keep-unused", action="store_true")
    s.add_argument("--kit-only", action="store_true")
    m = sub.add_parser("missing")
    m.add_argument("--table", choices=list(CATALOGS))
    m.add_argument("--source")
    c = sub.add_parser("check")
    c.add_argument("--kit-only", action="store_true")
    args = parser.parse_args()

    sources = {"HeatPumpKit": kit_keys()}
    if not getattr(args, "kit_only", False):
        sources["Localizable"] = app_keys()

    if args.command == "sync":
        translations = read_translations(args.translations)
        for table, keys in sources.items():
            added, removed, applied = merge(table, keys, translations[table], args.keep_unused, table == "HeatPumpKit")
            print(f"{table}: {len(keys)} keys, +{len(added)} new, -{len(removed)} unused, {applied} translations applied")
        return

    if args.command == "missing":
        for table, keys in sources.items():
            if args.table and table != args.table:
                continue
            strings = load(table)["strings"]
            for key, paths in sorted(keys.items()):
                if args.source and not any(p.startswith(args.source) for p in paths):
                    continue
                if key not in strings or not has_translation(strings[key]):
                    print(f"[{table}] {sorted(set(paths))[0]}: {json.dumps(key, ensure_ascii=False)}")
        return

    problems = []
    for table, keys in sources.items():
        strings = load(table)["strings"]
        problems += [f"[{table}] not in catalog: {k!r}" for k in keys if k not in strings]
        problems += [f"[{table}] unused in catalog: {k!r}" for k in strings if k not in keys]
        problems += [f"[{table}] no Norwegian translation: {k!r}" for k in keys if k in strings and not has_translation(strings[k])]
    if problems:
        print("\n".join(problems))
        print(f"{len(problems)} problem(s). Run `make l10n` and add the missing translations.")
        sys.exit(1)
    print("String catalogs are in sync and fully translated.")


if __name__ == "__main__":
    main()
