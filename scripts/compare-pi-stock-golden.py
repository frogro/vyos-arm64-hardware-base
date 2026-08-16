#!/usr/bin/env python3

from pathlib import Path
import argparse
import difflib
import re
import shutil

ap = argparse.ArgumentParser()
ap.add_argument("--stock-root", default="/mnt/rpi-a-root")
ap.add_argument("--stock-boot", default="/mnt/rpi-a-boot")
ap.add_argument("--golden", default="/tmp/pi-golden-ref")
ap.add_argument("--out", default="analysis/pi-stock-vs-golden")
args = ap.parse_args()

stock_root = Path(args.stock_root)
stock_boot = Path(args.stock_boot)
golden = Path(args.golden)
out = Path(args.out)

KREL = "7.1.8-edge-bcm2711"

if out.exists():
    shutil.rmtree(out)

for d in (
    "config",
    "modules",
    "firmware",
    "boot",
    "packages",
):
    (out / d).mkdir(parents=True, exist_ok=True)


def write_lines(path, rows):
    path = Path(path)
    with path.open("w", encoding="utf-8") as f:
        for row in rows:
            if isinstance(row, (tuple, list)):
                f.write("\t".join(str(x) for x in row) + "\n")
            else:
                f.write(str(row) + "\n")


# ----------------------------------------------------------------------
# Kernel config
# ----------------------------------------------------------------------

def parse_config(path):
    result = {}
    rx_set = re.compile(r"^(CONFIG_[A-Za-z0-9_]+)=(.*)$")
    rx_unset = re.compile(r"^# (CONFIG_[A-Za-z0-9_]+) is not set$")

    for line in path.read_text(errors="replace").splitlines():
        m = rx_set.match(line)
        if m:
            result[m.group(1)] = m.group(2)
            continue

        m = rx_unset.match(line)
        if m:
            result[m.group(1)] = "n"

    return result


stock_cfg_path = stock_root / "boot" / f"config-{KREL}"
golden_cfg_path = golden / "kernel" / f"config-{KREL}"

if not stock_cfg_path.exists():
    raise SystemExit(f"Stock config fehlt: {stock_cfg_path}")

if not golden_cfg_path.exists():
    raise SystemExit(f"Golden config fehlt: {golden_cfg_path}")

stock_cfg = parse_config(stock_cfg_path)
golden_cfg = parse_config(golden_cfg_path)

all_symbols = sorted(set(stock_cfg) | set(golden_cfg))

all_config = []
delta = []
added = []
disabled = []
value_changed = []

for sym in all_symbols:
    sv = stock_cfg.get(sym, "<missing>")
    gv = golden_cfg.get(sym, "<missing>")

    all_config.append((sym, sv, gv))

    # For functional comparison, an absent Kconfig symbol and an
    # explicitly disabled symbol are equivalent.
    svn = "n" if sv in ("n", "<missing>") else sv
    gvn = "n" if gv in ("n", "<missing>") else gv

    if svn == gvn:
        continue

    if svn == "n" and gvn != "n":
        cls = "golden-added"
        added.append((sym, sv, gv))
    elif svn != "n" and gvn == "n":
        cls = "golden-disabled"
        disabled.append((sym, sv, gv))
    else:
        cls = "value-changed"
        value_changed.append((sym, sv, gv))

    delta.append((sym, sv, gv, cls))

write_lines(out / "config/all.tsv", all_config)
write_lines(out / "config/complete-delta.tsv", delta)
write_lines(out / "config/golden-added.tsv", added)
write_lines(out / "config/golden-disabled.tsv", disabled)
write_lines(out / "config/value-changed.tsv", value_changed)


# ----------------------------------------------------------------------
# Modules
# ----------------------------------------------------------------------

modroot = stock_root / "usr" / "lib" / "modules" / KREL
if not modroot.exists():
    modroot = stock_root / "lib" / "modules" / KREL

if not modroot.exists():
    raise SystemExit(f"Stock module tree fehlt: {modroot}")


def canonical_module_filename(name):
    name = re.sub(r"\.ko(?:\.(?:xz|zst|gz))?$", "", name)
    return name.replace("-", "_")


stock_modules = {}

for p in modroot.rglob("*"):
    if not p.is_file():
        continue

    if not re.search(r"\.ko(?:\.(?:xz|zst|gz))?$", p.name):
        continue

    name = canonical_module_filename(p.name)
    rel = p.relative_to(modroot).as_posix()
    stock_modules.setdefault(name, rel)


golden_modules = {}

golden_module_file = golden / "modules" / "modules-files.tsv"

for line in golden_module_file.read_text(errors="replace").splitlines():
    parts = line.split("\t")

    if len(parts) < 4:
        continue

    name = parts[2].replace("-", "_")
    path = parts[3]
    golden_modules.setdefault(name, path)


stock_names = set(stock_modules)
golden_names = set(golden_modules)

common_modules = sorted(stock_names & golden_names)
golden_added_modules = sorted(golden_names - stock_names)
stock_only_modules = sorted(stock_names - golden_names)

write_lines(
    out / "modules/stock.tsv",
    ((x, stock_modules[x]) for x in sorted(stock_names)),
)

write_lines(
    out / "modules/golden.tsv",
    ((x, golden_modules[x]) for x in sorted(golden_names)),
)

write_lines(
    out / "modules/common.txt",
    common_modules,
)

write_lines(
    out / "modules/golden-added.tsv",
    ((x, golden_modules[x]) for x in golden_added_modules),
)

write_lines(
    out / "modules/stock-only.tsv",
    ((x, stock_modules[x]) for x in stock_only_modules),
)


# ----------------------------------------------------------------------
# Firmware
# ----------------------------------------------------------------------

fwroot = stock_root / "usr" / "lib" / "firmware"
if not fwroot.exists():
    fwroot = stock_root / "lib" / "firmware"

stock_fw = set()

if fwroot.exists():
    for p in fwroot.rglob("*"):
        if not (p.is_file() or p.is_symlink()):
            continue

        rel = p.relative_to(fwroot).as_posix()
        stock_fw.add(rel)

        # Compressed firmware satisfies the same firmware request.
        if rel.endswith(".zst"):
            stock_fw.add(rel[:-4])
        elif rel.endswith(".xz"):
            stock_fw.add(rel[:-3])


golden_required_fw = set()

for line in (golden / "firmware" / "firmware-required.txt").read_text(
    errors="replace"
).splitlines():
    line = line.strip()
    if line:
        golden_required_fw.add(line)


fw_present = sorted(golden_required_fw & stock_fw)
fw_missing = sorted(golden_required_fw - stock_fw)

write_lines(out / "firmware/stock-all-normalized.txt", sorted(stock_fw))
write_lines(out / "firmware/golden-required.txt", sorted(golden_required_fw))
write_lines(out / "firmware/required-present-in-stock.txt", fw_present)
write_lines(out / "firmware/required-missing-from-stock.txt", fw_missing)


# ----------------------------------------------------------------------
# DTBs / overlays
# ----------------------------------------------------------------------

stock_dtb = set()

for root in (stock_boot, stock_root / "boot"):
    if not root.exists():
        continue

    for p in root.rglob("*"):
        if p.is_file() and p.suffix in (".dtb", ".dtbo"):
            stock_dtb.add(p.name)


golden_dtb = set()

for line in (golden / "boot" / "dtb-overlay.tsv").read_text(
    errors="replace"
).splitlines():
    parts = line.split("\t")

    if len(parts) < 3:
        continue

    golden_dtb.add(Path(parts[2]).name)


write_lines(out / "boot/stock-dtb-basenames.txt", sorted(stock_dtb))
write_lines(out / "boot/golden-dtb-basenames.txt", sorted(golden_dtb))
write_lines(out / "boot/common-dtb.txt", sorted(stock_dtb & golden_dtb))
write_lines(out / "boot/golden-dtb-added.txt", sorted(golden_dtb - stock_dtb))
write_lines(out / "boot/stock-dtb-only.txt", sorted(stock_dtb - golden_dtb))


# ----------------------------------------------------------------------
# Boot text comparison
# ----------------------------------------------------------------------

boot_pairs = [
    (
        golden / "boot/text/firmware__cmdline.txt",
        stock_boot / "cmdline.txt",
        "cmdline.diff",
    ),
    (
        golden / "boot/text/firmware__config.txt",
        stock_boot / "config.txt",
        "config.txt.diff",
    ),
    (
        golden / "boot/text/armbianEnv.txt",
        stock_root / "boot/armbianEnv.txt",
        "armbianEnv.diff",
    ),
]

for gp, sp, name in boot_pairs:
    if not gp.exists():
        continue

    golden_lines = gp.read_text(errors="replace").splitlines(True)

    if sp.exists():
        stock_lines = sp.read_text(errors="replace").splitlines(True)
    else:
        stock_lines = []

    diff = difflib.unified_diff(
        stock_lines,
        golden_lines,
        fromfile=f"stock/{sp.name}",
        tofile=f"golden/{gp.name}",
    )

    (out / "boot" / name).write_text("".join(diff), encoding="utf-8")


# ----------------------------------------------------------------------
# Packages
# ----------------------------------------------------------------------

golden_manual = set()

pkgfile = golden / "packages/manual-packages-installed.tsv"

for line in pkgfile.read_text(errors="replace").splitlines():
    if not line.strip():
        continue

    golden_manual.add(line.split("\t", 1)[0])


stock_installed = set()
status_file = stock_root / "var/lib/dpkg/status"

if status_file.exists():
    for para in status_file.read_text(errors="replace").split("\n\n"):
        package = None
        installed = False

        for line in para.splitlines():
            if line.startswith("Package: "):
                package = line[9:].strip()

            elif line == "Status: install ok installed":
                installed = True

        if package and installed:
            stock_installed.add(package)


write_lines(out / "packages/golden-manual.txt", sorted(golden_manual))
write_lines(out / "packages/stock-installed.txt", sorted(stock_installed))

write_lines(
    out / "packages/golden-manual-already-in-stock.txt",
    sorted(golden_manual & stock_installed),
)

write_lines(
    out / "packages/golden-manual-not-in-stock.txt",
    sorted(golden_manual - stock_installed),
)


# ----------------------------------------------------------------------
# Summary
# ----------------------------------------------------------------------

summary = f"""PI STOCK -> GOLDEN RAW DELTA
================================

Kernel:
  {KREL}

CONFIG
------
Stock symbols:              {len(stock_cfg)}
Golden symbols:             {len(golden_cfg)}
Changed total:              {len(delta)}
Golden added/enabled:       {len(added)}
Golden disabled:            {len(disabled)}
Value changed:              {len(value_changed)}

LOADABLE MODULES
----------------
Stock unique modules:       {len(stock_names)}
Golden unique modules:      {len(golden_names)}
Common:                     {len(common_modules)}
Golden added:               {len(golden_added_modules)}
Stock only:                 {len(stock_only_modules)}

FIRMWARE
--------
Golden required:            {len(golden_required_fw)}
Already available in stock: {len(fw_present)}
Missing from stock:         {len(fw_missing)}

DTB / OVERLAYS
--------------
Stock basenames:             {len(stock_dtb)}
Golden basenames:            {len(golden_dtb)}
Common:                     {len(stock_dtb & golden_dtb)}
Golden-only basenames:       {len(golden_dtb - stock_dtb)}
Stock-only basenames:        {len(stock_dtb - golden_dtb)}

PACKAGES
--------
Golden manual packages:     {len(golden_manual)}
Already installed in stock: {len(golden_manual & stock_installed)}
Not installed in stock:     {len(golden_manual - stock_installed)}

NOTE
----
This is the RAW comparison only.

Nothing in this output has yet been classified as:
  portable
  Pi-specific
  SoC-specific
  architecture-specific
  build/debug noise
  dependency-only
"""

(out / "SUMMARY.txt").write_text(summary, encoding="utf-8")

print(summary)
print(f"Results written to: {out}")
