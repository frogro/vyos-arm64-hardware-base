#!/usr/bin/env python3

import argparse
import csv
import os
from pathlib import Path


def tristate(v):
    return {
        0: "n",
        1: "m",
        2: "y",
    }.get(v, str(v))


def write_tsv(path, rows, fields):
    path.parent.mkdir(parents=True, exist_ok=True)

    with path.open("w", newline="") as f:
        w = csv.DictWriter(
            f,
            fieldnames=fields,
            delimiter="\t",
            extrasaction="ignore",
        )
        w.writeheader()
        w.writerows(rows)


def main():
    ap = argparse.ArgumentParser()

    ap.add_argument(
        "--kroot",
        default=(
            "/mnt/datenplatte/vyos-c-ref/"
            "rpi-linux-db6416f1b6285aca5374ce23ed3b2fb07bf7529e-kconfig"
        ),
    )

    ap.add_argument(
        "--b-config",
        default="/mnt/datenplatte/vyos-c-ref/b-pi-final.config",
    )

    ap.add_argument(
        "--candidates",
        default="analysis/c-pi-raw/vyos-enabled-b-disabled.tsv",
    )

    ap.add_argument(
        "--out",
        default="analysis/c-pi-source-aware",
    )

    args = ap.parse_args()

    kroot = Path(args.kroot).resolve()
    bconfig = Path(args.b_config).resolve()
    candidates = Path(args.candidates).resolve()
    out = Path(args.out)

    for required in (
        kroot / "Kconfig",
        kroot / "Makefile",
        bconfig,
        candidates,
    ):
        if not required.exists():
            raise SystemExit(f"ERROR: missing: {required}")

    #
    # ARM64 kernel context
    #
    os.environ["srctree"] = str(kroot)
    os.environ["ARCH"] = "arm64"
    os.environ["SRCARCH"] = "arm64"
    os.environ["KERNELVERSION"] = "7.1.8"

    os.environ["CC"] = "aarch64-linux-gnu-gcc"
    os.environ["LD"] = "aarch64-linux-gnu-ld"

    os.environ["HOSTCC"] = "gcc"
    os.environ["HOSTCXX"] = "g++"

    os.chdir(kroot)

    import kconfiglib

    print("===== LOAD ARM64 KCONFIG GRAPH =====")

    kconf = kconfiglib.Kconfig(
        "Kconfig",
        warn=False,
        suppress_traceback=True,
    )

    print(f"Kconfig symbols in ARM64 graph: {len(kconf.syms)}")

    #
    # Load validated B/Pi final config
    #
    print()
    print("===== LOAD VALIDATED B CONFIG =====")

    msg = kconf.load_config(
        str(bconfig),
        replace=True,
    )

    print(msg)

    #
    # Read the 707 VyOS-enabled / B-disabled candidates
    #
    with candidates.open() as f:
        rows = list(csv.DictReader(f, delimiter="\t"))

    result = []

    defined = []
    not_defined = []

    direct = []
    alternate_mode = []
    dependency_blocked = []
    hidden = []

    for row in rows:
        config_name = row["symbol"]

        if not config_name.startswith("CONFIG_"):
            raise SystemExit(
                f"ERROR: unexpected symbol: {config_name}"
            )

        name = config_name[7:]
        sym = kconf.syms.get(name)

        base = {
            "symbol": config_name,
            "b_file_value": row["b_value"],
            "vyos_value": row["vyos_value"],
            "b_present": row["b_present"],
        }

        if sym is None:
            r = {
                **base,
                "arm64_defined": "0",
                "arm64_value": "n",
                "type": "",
                "visibility": "",
                "assignable": "",
                "target_exact_assignable": "0",
                "functional_enable_assignable": "0",
                "has_prompt": "0",
                "state": "not-defined-in-arm64-graph",
                "prompt": "",
                "locations": "",
                "direct_dep": "",
                "selected_by": "",
                "implied_by": "",
            }

            result.append(r)
            not_defined.append(r)
            continue

        prompts = []
        locations = []

        for node in sym.nodes:
            locations.append(
                f"{node.filename}:{node.linenr}"
            )

            if node.prompt:
                prompts.append(node.prompt[0])

        prompts = list(dict.fromkeys(prompts))
        locations = list(dict.fromkeys(locations))

        assignable = tuple(
            tristate(x)
            for x in sym.assignable
        )

        target = row["vyos_value"]

        exact = target in assignable

        enable_assignable = any(
            x in assignable
            for x in ("m", "y")
        )

        has_prompt = bool(prompts)

        if exact:
            state = "direct-settable-to-vyos-value"

        elif enable_assignable:
            state = "settable-enabled-different-mode"

        elif not has_prompt:
            state = "hidden-derived-or-selected"

        else:
            state = "dependency-blocked"

        type_name = {
            kconfiglib.BOOL: "bool",
            kconfiglib.TRISTATE: "tristate",
            kconfiglib.STRING: "string",
            kconfiglib.INT: "int",
            kconfiglib.HEX: "hex",
            kconfiglib.UNKNOWN: "unknown",
        }.get(
            sym.type,
            str(sym.type),
        )

        r = {
            **base,
            "arm64_defined": "1",
            "arm64_value": sym.str_value,
            "type": type_name,
            "visibility": tristate(sym.visibility),
            "assignable": ",".join(assignable),
            "target_exact_assignable": "1" if exact else "0",
            "functional_enable_assignable":
                "1" if enable_assignable else "0",
            "has_prompt": "1" if has_prompt else "0",
            "state": state,
            "prompt": " | ".join(prompts),
            "locations": " | ".join(locations),
            "direct_dep":
                kconfiglib.expr_str(sym.direct_dep),
            "selected_by":
                kconfiglib.expr_str(sym.rev_dep),
            "implied_by":
                kconfiglib.expr_str(sym.weak_rev_dep),
        }

        result.append(r)
        defined.append(r)

        if state == "direct-settable-to-vyos-value":
            direct.append(r)

        elif state == "settable-enabled-different-mode":
            alternate_mode.append(r)

        elif state == "dependency-blocked":
            dependency_blocked.append(r)

        elif state == "hidden-derived-or-selected":
            hidden.append(r)

    fields = [
        "symbol",
        "b_file_value",
        "vyos_value",
        "b_present",
        "arm64_defined",
        "arm64_value",
        "type",
        "visibility",
        "assignable",
        "target_exact_assignable",
        "functional_enable_assignable",
        "has_prompt",
        "state",
        "prompt",
        "locations",
        "direct_dep",
        "selected_by",
        "implied_by",
    ]

    write_tsv(
        out / "all-enable-candidates.tsv",
        result,
        fields,
    )

    write_tsv(
        out / "defined-on-arm64.tsv",
        defined,
        fields,
    )

    write_tsv(
        out / "not-defined-on-arm64.tsv",
        not_defined,
        fields,
    )

    write_tsv(
        out / "direct-settable.tsv",
        direct,
        fields,
    )

    write_tsv(
        out / "alternate-mode.tsv",
        alternate_mode,
        fields,
    )

    write_tsv(
        out / "dependency-blocked.tsv",
        dependency_blocked,
        fields,
    )

    write_tsv(
        out / "hidden-derived.tsv",
        hidden,
        fields,
    )

    print()
    print("===== C/Pi ARM64 SOURCE-AWARE RESULT =====")
    print()
    print(
        f"Candidates total:                 {len(result)}"
    )
    print(
        f"Defined in ARM64 graph:           {len(defined)}"
    )
    print(
        f"Not defined in ARM64 graph:       {len(not_defined)}"
    )
    print()
    print(
        f"Directly settable to VyOS value:  {len(direct)}"
    )
    print(
        f"Settable, alternate y/m mode:     {len(alternate_mode)}"
    )
    print(
        f"Dependency blocked:               {len(dependency_blocked)}"
    )
    print(
        f"Hidden / derived / selected:      {len(hidden)}"
    )
    print()
    print(f"Output: {out}")


if __name__ == "__main__":
    main()
