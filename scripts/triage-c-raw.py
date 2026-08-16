#!/usr/bin/env python3

from pathlib import Path
import csv


BASE = Path("analysis/c-pi-raw")
OUT = Path("analysis/c-pi-triage")


def read_tsv(name):
    path = BASE / name

    with path.open() as f:
        return list(csv.DictReader(f, delimiter="\t"))


def write_tsv(name, rows, fields):
    OUT.mkdir(parents=True, exist_ok=True)

    path = OUT / name

    with path.open("w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=fields, delimiter="\t")
        w.writeheader()
        w.writerows(rows)


enabled = read_tsv("vyos-enabled-b-disabled.tsv")
disabled = read_tsv("b-enabled-vyos-disabled.tsv")
modes = read_tsv("mode-changes.tsv")
values = read_tsv("value-changes.tsv")


enable_same = [
    r for r in enabled
    if r["b_present"] == "1"
]

enable_absent = [
    r for r in enabled
    if r["b_present"] == "0"
]


disable_same = [
    r for r in disabled
    if r["vyos_present"] == "1"
]

disable_absent = [
    r for r in disabled
    if r["vyos_present"] == "0"
]


mode_b_m_v_y = [
    r for r in modes
    if r["b_value"] == "m" and r["vyos_value"] == "y"
]

mode_b_y_v_m = [
    r for r in modes
    if r["b_value"] == "y" and r["vyos_value"] == "m"
]


value_common = [
    r for r in values
    if r["b_present"] == "1" and r["vyos_present"] == "1"
]

value_vyos_only = [
    r for r in values
    if r["b_present"] == "0" and r["vyos_present"] == "1"
]

value_b_only = [
    r for r in values
    if r["b_present"] == "1" and r["vyos_present"] == "0"
]


fields5 = [
    "symbol",
    "b_value",
    "vyos_value",
    "b_present",
    "vyos_present",
]


write_tsv(
    "enable-same-symbol.tsv",
    enable_same,
    fields5,
)

write_tsv(
    "enable-absent-on-b.tsv",
    enable_absent,
    fields5,
)

write_tsv(
    "disable-same-symbol.tsv",
    disable_same,
    fields5,
)

write_tsv(
    "disable-absent-on-vyos.tsv",
    disable_absent,
    fields5,
)

write_tsv(
    "mode-b-m-v-y.tsv",
    mode_b_m_v_y,
    fields5,
)

write_tsv(
    "mode-b-y-v-m.tsv",
    mode_b_y_v_m,
    fields5,
)

write_tsv(
    "value-common.tsv",
    value_common,
    fields5,
)

write_tsv(
    "value-vyos-only.tsv",
    value_vyos_only,
    fields5,
)

write_tsv(
    "value-b-only.tsv",
    value_b_only,
    fields5,
)


print("===== C/Pi STRUCTURAL TRIAGE =====")
print()
print("ENABLE DELTA")
print(f"Same symbol exists in B:       {len(enable_same)}")
print(f"Symbol absent from B config:   {len(enable_absent)}")
print(f"Total:                         {len(enabled)}")
print()
print("DISABLE DELTA")
print(f"Same symbol exists in VyOS:    {len(disable_same)}")
print(f"Symbol absent from VyOS:       {len(disable_absent)}")
print(f"Total:                         {len(disabled)}")
print()
print("MODE DELTA")
print(f"B=m -> VyOS=y:                 {len(mode_b_m_v_y)}")
print(f"B=y -> VyOS=m:                 {len(mode_b_y_v_m)}")
print(f"Total:                         {len(modes)}")
print()
print("VALUE DELTA")
print(f"Present in both configs:       {len(value_common)}")
print(f"Present only in VyOS:          {len(value_vyos_only)}")
print(f"Present only in B:             {len(value_b_only)}")
print(f"Total:                         {len(values)}")
print()
print(f"Output: {OUT}")
