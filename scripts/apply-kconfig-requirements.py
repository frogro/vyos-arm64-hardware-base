#!/usr/bin/env python3

from pathlib import Path
import argparse
import re

p = argparse.ArgumentParser()
p.add_argument("base")
p.add_argument("requirements")
p.add_argument("output")
args = p.parse_args()

base = Path(args.base)
reqfile = Path(args.requirements)
output = Path(args.output)

lines = base.read_text(errors="replace").splitlines()

requirements = {}
for line in reqfile.read_text(errors="replace").splitlines():
    if not line.strip():
        continue
    symbol, value = line.split("\t", 1)
    requirements[symbol] = value

found = set()
result = []

rx_set = re.compile(r"^(CONFIG_[A-Za-z0-9_]+)=.*$")
rx_unset = re.compile(r"^# (CONFIG_[A-Za-z0-9_]+) is not set$")

for line in lines:
    m = rx_set.match(line) or rx_unset.match(line)

    if not m:
        result.append(line)
        continue

    symbol = m.group(1)

    if symbol not in requirements:
        result.append(line)
        continue

    value = requirements[symbol]
    found.add(symbol)

    if value == "n":
        result.append(f"# {symbol} is not set")
    else:
        result.append(f"{symbol}={value}")

for symbol in sorted(set(requirements) - found):
    value = requirements[symbol]

    if value == "n":
        result.append(f"# {symbol} is not set")
    else:
        result.append(f"{symbol}={value}")

output.parent.mkdir(parents=True, exist_ok=True)
output.write_text("\n".join(result) + "\n")

print(f"Requirements total      : {len(requirements)}")
print(f"Found in base           : {len(found)}")
print(f"Appended to base        : {len(requirements) - len(found)}")
print(f"Output                  : {output}")
