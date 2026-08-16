#!/usr/bin/env python3

from pathlib import Path
import re
import shutil

BASE = Path("analysis/pi-stock-vs-golden")
OUT  = Path("analysis/b-source-requirements")

if OUT.exists():
    shutil.rmtree(OUT)

for d in (
    "portable-direct",
    "source-board-specific",
    "build-noise",
    "mode-review",
    "disabled-review",
):
    (OUT / d).mkdir(parents=True, exist_ok=True)

# Deliberately conservative:
# only symbols that are clearly Raspberry-Pi-family-specific
# are classified as source-board-specific.
PI_PATTERNS = [
    r"RASPBERRYPI",
    r"BCM2835",
    r"BCM2711",
    r"BCM2712",
    r"(^|_)RP1($|_)",
    r"VCHIQ",
    r"VC4",
    r"RPI_FIRMWARE",
]

# Compiler/build identity is not a hardware capability.
BUILD_PATTERNS = [
    r"^CONFIG_CC_VERSION_TEXT$",
    r"^CONFIG_GCC_VERSION$",
    r"^CONFIG_CLANG_VERSION$",
    r"^CONFIG_AS_VERSION$",
    r"^CONFIG_LD_VERSION$",
    r"^CONFIG_LLD_VERSION$",
    r"^CONFIG_PAHOLE_VERSION$",
    r"^CONFIG_RUSTC_VERSION$",
    r"^CONFIG_RUSTC_LLVM_VERSION$",
    r"^CONFIG_RUSTC_LLVM_MAJOR_VERSION$",
]

def matches_any(symbol, patterns):
    return any(re.search(p, symbol) for p in patterns)

def read_tsv(path):
    rows = []
    if not path.exists():
        return rows
    for line in path.read_text(errors="replace").splitlines():
        if line.strip():
            rows.append(line.split("\t"))
    return rows

def write(path, rows):
    with path.open("w") as f:
        for row in rows:
            f.write("\t".join(row) + "\n")

added = read_tsv(BASE / "config/golden-added.tsv")
changed = read_tsv(BASE / "config/value-changed.tsv")
disabled = read_tsv(BASE / "config/golden-disabled.tsv")

portable = []
board_specific = []
noise = []
mode_review = []
value_review = []

for row in added:
    sym, stock, golden = row[:3]

    if matches_any(sym, BUILD_PATTERNS):
        noise.append([sym, stock, golden, "build-metadata"])

    elif matches_any(sym, PI_PATTERNS):
        board_specific.append([
            sym, stock, golden,
            "source-pi-specific",
            "check-functional-counterpart-on-target"
        ])

    else:
        # This is our agreed rule:
        # everything else remains a B requirement candidate.
        portable.append([
            sym, stock, golden,
            "portable-direct"
        ])

for row in changed:
    sym, stock, golden = row[:3]

    if matches_any(sym, BUILD_PATTERNS):
        noise.append([sym, stock, golden, "build-metadata"])
        continue

    # y <-> m does not add/remove the capability.
    if {stock, golden} <= {"y", "m"}:
        mode_review.append([
            sym, stock, golden,
            "function-already-present",
            "do-not-force-mode-unless-required"
        ])
        continue

    value_review.append([
        sym, stock, golden,
        "value-review"
    ])

disabled_review = []
for row in disabled:
    disabled_review.append(row[:3] + [
        "golden-disabled-review"
    ])

write(OUT / "portable-direct/kernel-config.tsv", portable)
write(OUT / "source-board-specific/kernel-config.tsv", board_specific)
write(OUT / "build-noise/kernel-config.tsv", noise)
write(OUT / "mode-review/kernel-config.tsv", mode_review + value_review)
write(OUT / "disabled-review/kernel-config.tsv", disabled_review)

summary = f"""B SOURCE REQUIREMENT CLASSIFICATION
===================================

Source:
  Factory A / rpi4b -> Golden Pi

Raw functional delta:
  enabled/additional: {len(added)}
  value/mode changes: {len(changed)}
  disabled:           {len(disabled)}

Initial classification:
  portable-direct:        {len(portable)}
  source-board-specific:  {len(board_specific)}
  build-noise:            {len(noise)}
  mode/value review:      {len(mode_review) + len(value_review)}
  disabled review:        {len(disabled_review)}

RULES
-----
portable-direct:
  Preserve as a B capability requirement.

source-board-specific:
  Do NOT copy the Pi symbol blindly.
  Check whether the target board/kernel has an equivalent capability.

build-noise:
  Compiler/build identity only; not a B capability.

mode/value review:
  Capability already existed in Stock A or value needs semantic review.

disabled review:
  Never disable globally until the Golden reason is understood.
"""

(OUT / "SUMMARY.txt").write_text(summary)
print(summary)
