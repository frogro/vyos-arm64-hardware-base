#!/usr/bin/env python3

from pathlib import Path
from collections import defaultdict
import argparse
import csv
import re


TOPLEVEL = re.compile(
    r'^(config|menuconfig|comment|menu|endmenu|choice|endchoice|'
    r'if|endif|source|rsource|osource)\b'
)

CONFIG = re.compile(
    r'^\s*(config|menuconfig)\s+([A-Za-z0-9_]+)\s*$'
)


def scan_tree(root):
    definitions = defaultdict(list)

    files = []

    for p in root.rglob("*"):
        if not p.is_file():
            continue

        if p.name == "Kconfig" or p.name.startswith("Kconfig."):
            files.append(p)

    for path in files:
        lines = path.read_text(errors="replace").splitlines()

        i = 0

        while i < len(lines):
            m = CONFIG.match(lines[i])

            if not m:
                i += 1
                continue

            kind = m.group(1)
            name = m.group(2)
            start = i

            i += 1

            while i < len(lines):
                if CONFIG.match(lines[i]):
                    break

                # A new top-level Kconfig construct ends the current
                # definition. Indented "if"/etc. stay part of the block.
                if (
                    lines[i] == lines[i].lstrip()
                    and TOPLEVEL.match(lines[i])
                ):
                    break

                i += 1

            definitions[name].append({
                "kind": kind,
                "path": str(path.relative_to(root)),
                "line": start + 1,
                "block": lines[start:i],
            })

    return definitions


def metadata(d):
    typ = ""
    prompt = ""
    depends = []
    selects = []
    implies = []
    defaults = []

    in_help = False
    help_text = []

    for line in d["block"][1:]:
        s = line.strip()

        if not s:
            continue

        tm = re.match(
            r'^(bool|tristate|string|int|hex|def_bool|def_tristate)\b(.*)$',
            s
        )

        if tm:
            typ = tm.group(1)

            q = re.search(r'"([^"]+)"', tm.group(2))
            if q:
                prompt = q.group(1)

        m = re.match(r'^depends on\s+(.+)$', s)
        if m:
            depends.append(m.group(1))

        m = re.match(
            r'^select\s+([A-Za-z0-9_]+)(?:\s+if\s+(.+))?$',
            s
        )
        if m:
            value = m.group(1)
            if m.group(2):
                value += " if " + m.group(2)
            selects.append(value)

        m = re.match(
            r'^imply\s+([A-Za-z0-9_]+)(?:\s+if\s+(.+))?$',
            s
        )
        if m:
            value = m.group(1)
            if m.group(2):
                value += " if " + m.group(2)
            implies.append(value)

        m = re.match(r'^default\s+(.+)$', s)
        if m:
            defaults.append(m.group(1))

        if s in ("help", "---help---"):
            in_help = True
            continue

        if in_help and len(help_text) < 4:
            help_text.append(s)

    return {
        "type": typ,
        "prompt": prompt,
        "user_settable": int(
            bool(prompt)
            and typ not in ("def_bool", "def_tristate")
        ),
        "depends": " && ".join(depends),
        "selects": "; ".join(selects),
        "implies": "; ".join(implies),
        "defaults": "; ".join(defaults),
        "help": " ".join(help_text),
    }


def main():
    ap = argparse.ArgumentParser()

    ap.add_argument("--kernel-tree", required=True)
    ap.add_argument("--symbols", required=True)
    ap.add_argument("--output", required=True)

    args = ap.parse_args()

    root = Path(args.kernel_tree)
    source = Path(args.symbols)
    output = Path(args.output)

    definitions = scan_tree(root)

    with source.open() as f:
        input_rows = list(csv.DictReader(f, delimiter="\t"))

    rows = []

    for r in input_rows:
        sym = r["symbol"]
        bare = sym.removeprefix("CONFIG_")

        defs = definitions.get(bare, [])

        if not defs:
            rows.append({
                "symbol": sym,
                "wanted": r.get("wanted", r.get("vyos_value", "")),
                "definition_count": 0,
            })
            continue

        for d in defs:
            rows.append({
                "symbol": sym,
                "wanted": r.get("wanted", r.get("vyos_value", "")),
                "definition_count": len(defs),
                "path": d["path"],
                "line": d["line"],
                **metadata(d),
            })

    fields = [
        "symbol",
        "wanted",
        "definition_count",
        "path",
        "line",
        "type",
        "prompt",
        "user_settable",
        "depends",
        "selects",
        "implies",
        "defaults",
        "help",
    ]

    output.parent.mkdir(parents=True, exist_ok=True)

    with output.open("w", newline="") as f:
        w = csv.DictWriter(
            f,
            fieldnames=fields,
            delimiter="\t",
            extrasaction="ignore",
        )
        w.writeheader()
        w.writerows(rows)

    print(f"symbols requested : {len(input_rows)}")
    print(f"metadata rows     : {len(rows)}")
    print(f"output            : {output}")


if __name__ == "__main__":
    main()
