#!/usr/bin/env python3

from pathlib import Path
import argparse
import csv


def read_config(path):
    values = {}
    present = set()

    for line in Path(path).read_text().splitlines():
        if line.startswith("CONFIG_") and "=" in line:
            key, value = line.split("=", 1)
            values[key] = value
            present.add(key)

        elif line.startswith("# CONFIG_") and line.endswith(" is not set"):
            key = line[len("# "):].split(" is not set", 1)[0]
            values[key] = "n"
            present.add(key)

    return values, present


def functional_value(values, key):
    return values.get(key, "n")


def write_tsv(path, rows, header):
    path.parent.mkdir(parents=True, exist_ok=True)

    with path.open("w", newline="") as f:
        writer = csv.writer(f, delimiter="\t")
        writer.writerow(header)
        writer.writerows(rows)


def main():
    ap = argparse.ArgumentParser()

    ap.add_argument(
        "--b",
        default="/mnt/datenplatte/vyos-c-ref/b-pi-final.config",
    )
    ap.add_argument(
        "--vyos",
        default="/mnt/datenplatte/vyos-c-ref/official-vyos-kernel.config",
    )
    ap.add_argument(
        "--out",
        default="analysis/c-pi-raw",
    )

    args = ap.parse_args()

    b, bp = read_config(args.b)
    v, vp = read_config(args.vyos)

    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)

    keys = sorted(bp | vp)

    same = []
    differences = []

    vyos_enabled_b_disabled = []
    b_enabled_vyos_disabled = []
    mode_changes = []
    value_changes = []

    vyos_only = []
    b_only = []

    for key in keys:
        bv = functional_value(b, key)
        vv = functional_value(v, key)

        b_present = key in bp
        v_present = key in vp

        if b_present and not v_present:
            b_only.append((key, bv))

        if v_present and not b_present:
            vyos_only.append((key, vv))

        if bv == vv:
            same.append(
                (
                    key,
                    bv,
                    int(b_present),
                    int(v_present),
                )
            )
            continue

        if vv in ("y", "m") and bv == "n":
            kind = "vyos-enabled-b-disabled"
            vyos_enabled_b_disabled.append(
                (
                    key,
                    bv,
                    vv,
                    int(b_present),
                    int(v_present),
                )
            )

        elif bv in ("y", "m") and vv == "n":
            kind = "b-enabled-vyos-disabled"
            b_enabled_vyos_disabled.append(
                (
                    key,
                    bv,
                    vv,
                    int(b_present),
                    int(v_present),
                )
            )

        elif bv in ("y", "m") and vv in ("y", "m"):
            kind = "mode-change"
            mode_changes.append(
                (
                    key,
                    bv,
                    vv,
                    int(b_present),
                    int(v_present),
                )
            )

        else:
            kind = "value-change"
            value_changes.append(
                (
                    key,
                    bv,
                    vv,
                    int(b_present),
                    int(v_present),
                )
            )

        differences.append(
            (
                key,
                bv,
                vv,
                int(b_present),
                int(v_present),
                kind,
            )
        )

    write_tsv(
        out / "all-differences.tsv",
        differences,
        [
            "symbol",
            "b_value",
            "vyos_value",
            "b_present",
            "vyos_present",
            "kind",
        ],
    )

    write_tsv(
        out / "vyos-enabled-b-disabled.tsv",
        vyos_enabled_b_disabled,
        [
            "symbol",
            "b_value",
            "vyos_value",
            "b_present",
            "vyos_present",
        ],
    )

    write_tsv(
        out / "b-enabled-vyos-disabled.tsv",
        b_enabled_vyos_disabled,
        [
            "symbol",
            "b_value",
            "vyos_value",
            "b_present",
            "vyos_present",
        ],
    )

    write_tsv(
        out / "mode-changes.tsv",
        mode_changes,
        [
            "symbol",
            "b_value",
            "vyos_value",
            "b_present",
            "vyos_present",
        ],
    )

    write_tsv(
        out / "value-changes.tsv",
        value_changes,
        [
            "symbol",
            "b_value",
            "vyos_value",
            "b_present",
            "vyos_present",
        ],
    )

    write_tsv(
        out / "vyos-only-symbols.tsv",
        vyos_only,
        ["symbol", "vyos_value"],
    )

    write_tsv(
        out / "b-only-symbols.tsv",
        b_only,
        ["symbol", "b_value"],
    )

    print("===== B/Pi -> OFFICIAL VYOS RAW KCONFIG DELTA =====")
    print()
    print(f"B config symbols:                {len(bp)}")
    print(f"Official VyOS config symbols:    {len(vp)}")
    print(f"Union symbols:                   {len(keys)}")
    print(f"Functional matches:              {len(same)}")
    print(f"Functional differences:          {len(differences)}")
    print()
    print(f"VyOS enabled, B disabled:        {len(vyos_enabled_b_disabled)}")
    print(f"B enabled, VyOS disabled:        {len(b_enabled_vyos_disabled)}")
    print(f"Enabled y/m mode changes:        {len(mode_changes)}")
    print(f"Other value changes:             {len(value_changes)}")
    print()
    print(f"Symbols present only in VyOS:    {len(vyos_only)}")
    print(f"Symbols present only in B:       {len(b_only)}")
    print()
    print(f"Output directory: {out}")


if __name__ == "__main__":
    main()
