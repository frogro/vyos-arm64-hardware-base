#!/usr/bin/env bash
set -euo pipefail

ROOT="$(
    cd "$(dirname "${BASH_SOURCE[0]}")/.."
    pwd
)"

SNAP="${1:?usage: resolve-c-snapshot-target.sh SNAPSHOT TARGET}"
TARGET_NAME="${2:?usage: resolve-c-snapshot-target.sh SNAPSHOT TARGET}"

SNAP="$(realpath "$SNAP")"
TARGET="$SNAP/targets/$TARGET_NAME"

die() {
    echo "ERROR: $*" >&2
    exit 1
}

get_info() {
    local file="$1"
    local key="$2"

    awk -F= -v key="$key" '
        $1 == key {
            sub(/^[^=]*=/, "", $0)
            print
            exit
        }
    ' "$file"
}

[[ -s "$SNAP/SNAPSHOT-INFO.txt" ]] ||
    die "invalid snapshot: $SNAP"

[[ -s "$TARGET/SOURCE-INFO.txt" ]] ||
    die "invalid target: $TARGET"

TINFO="$TARGET/SOURCE-INFO.txt"

BOARD="$(get_info "$TINFO" board)"
BRANCH="$(get_info "$TINFO" branch)"
RELEASE="$(get_info "$TINFO" release)"
LINUXCONFIG="$(get_info "$TINFO" linux_config)"
LINUXSOURCEDIR="$(get_info "$TINFO" linux_source_dir)"
BASE_CONFIG="$(get_info "$TINFO" base_config)"
KERNEL_COMMIT="$(get_info "$TINFO" kernel_source_commit)"
KERNEL_PIN="$(get_info "$TINFO" kernel_branch_pinned)"

ARB="$(get_info "$SNAP/SNAPSHOT-INFO.txt" armbian_worktree)"

B_REQ="$ROOT/profiles/vyos-base/kernel-required.tsv"
C_REQ="$ROOT/profiles/vyos-parity/portable-requirements.tsv"

APPLY="$ROOT/scripts/apply-kconfig-requirements.py"

[[ -d "$ARB" ]] ||
    die "Armbian snapshot missing: $ARB"

[[ -f "$BASE_CONFIG" ]] ||
    die "base config missing: $BASE_CONFIG"

[[ -s "$B_REQ" ]] ||
    die "B requirements missing: $B_REQ"

[[ -s "$C_REQ" ]] ||
    die "C portable requirements missing: $C_REQ"

[[ -x "$APPLY" ]] ||
    die "apply-kconfig-requirements.py missing"

[[ "$KERNEL_COMMIT" =~ ^[0-9a-f]{40}$ ]] ||
    die "invalid pinned kernel commit: $KERNEL_COMMIT"

[[ "$KERNEL_PIN" == "commit:$KERNEL_COMMIT" ]] ||
    die "kernel pin mismatch"

#
# Validate requirement file format before doing expensive Armbian work.
#
python3 - "$B_REQ" "$C_REQ" <<'PY'
import sys
from pathlib import Path

for name in sys.argv[1:]:
    p = Path(name)
    count = 0

    for nr, raw in enumerate(
        p.read_text(errors="replace").splitlines(),
        1
    ):
        line = raw.strip()

        if not line or line.startswith("#"):
            continue

        fields = line.split("\t")

        if len(fields) != 2:
            raise SystemExit(
                f"ERROR: malformed requirement "
                f"{p}:{nr}: {raw!r}"
            )

        symbol, value = fields

        if not symbol.startswith("CONFIG_"):
            raise SystemExit(
                f"ERROR: bad symbol {p}:{nr}: {symbol}"
            )

        if not value:
            raise SystemExit(
                f"ERROR: empty value {p}:{nr}"
            )

        count += 1

    print(f"{p}: {count} requirements")
PY

OUT="$TARGET/c-resolution"
rm -rf "$OUT"
mkdir -p "$OUT"

USERPATCH="$ARB/userpatches/${LINUXCONFIG}.config"

mkdir -p "$ARB/userpatches"

#
# Profile C must be able to override Armbian's own kernel-config policy.
# Armbian deliberately disables some options such as MODULE_SIG and
# SECURITY_LOCKDOWN_LSM in its core hook.  A custom_kernel_config
# extension runs later and is therefore the correct place for C.
#
C_EXT_NAME="hwbase-c-parity"
C_EXT_DIR="$ARB/userpatches/extensions"
C_EXT="$C_EXT_DIR/${C_EXT_NAME}.sh"
C_EXT_REQ="$C_EXT_DIR/${C_EXT_NAME}.tsv"

echo
echo "============================================================"
echo " C SNAPSHOT TARGET RESOLUTION"
echo "============================================================"
echo
echo "Snapshot       : $SNAP"
echo "Target         : $TARGET_NAME"
echo "Board          : $BOARD"
echo "Branch         : $BRANCH"
echo "Release        : $RELEASE"
echo "Linux config   : $LINUXCONFIG"
echo "Kernel source  : $LINUXSOURCEDIR"
echo "Kernel commit  : $KERNEL_COMMIT"
echo "Kernel pin     : $KERNEL_PIN"
echo "Base config    : $BASE_CONFIG"
echo

echo "===== REQUIREMENT COUNTS ====="
echo "B:"
wc -l "$B_REQ"
echo "C portable:"
wc -l "$C_REQ"

echo
echo "===== CURRENT C PORTABLE REQUIREMENTS ====="
cat "$C_REQ"

#
# ------------------------------------------------------------
# B
# ------------------------------------------------------------
#

echo
echo "============================================================"
echo " STEP 1: RESOLVE CURRENT B IN FROZEN ARMBIAN CONTEXT"
echo "============================================================"

"$APPLY" \
    "$BASE_CONFIG" \
    "$B_REQ" \
    "$OUT/b-requested.config"

sudo install \
    -o "$(id -u)" \
    -g "$(id -g)" \
    -m 0644 \
    "$OUT/b-requested.config" \
    "$USERPATCH"

(
    cd "$ARB"

    ./compile.sh rewrite-kernel-config \
        PREFER_DOCKER=no \
        BOARD="$BOARD" \
        BRANCH="$BRANCH" \
        RELEASE="$RELEASE" \
        BUILD_DESKTOP=no \
        BUILD_MINIMAL=yes \
        KERNEL_BTF=no \
        KERNELBRANCH="$KERNEL_PIN"
) 2>&1 | tee "$OUT/b-armbian-rewrite.log"

KERNEL_TREE="$ARB/cache/sources/$LINUXSOURCEDIR"

[[ -d "$KERNEL_TREE" ]] ||
    die "Armbian kernel tree missing after B resolution: $KERNEL_TREE"

[[ -s "$KERNEL_TREE/.config" ]] ||
    die "full B .config missing after Armbian resolution"

cp "$KERNEL_TREE/.config" \
    "$OUT/b-resolved.config"

cp "$USERPATCH" \
    "$OUT/b-exported-defconfig.config"

B_KERNEL_HEAD="$(
    git -c safe.directory="$KERNEL_TREE" -C "$KERNEL_TREE" rev-parse HEAD
)"

echo
echo "===== B KERNEL SOURCE ====="
echo "Expected base commit : $KERNEL_COMMIT"
echo "Kernel tree HEAD     : $B_KERNEL_HEAD"

[[ "$B_KERNEL_HEAD" == "$KERNEL_COMMIT" ]] ||
    die "B kernel source mismatch: expected $KERNEL_COMMIT, got $B_KERNEL_HEAD"

#
# HEAD normally remains the pinned upstream base while Armbian patches
# live in the worktree. Record status rather than assuming a clean tree.
#
git -c safe.directory="$KERNEL_TREE" -C "$KERNEL_TREE" status --short \
    > "$OUT/b-kernel-tree-status.txt" || true

#
# ------------------------------------------------------------
# C
# ------------------------------------------------------------
#

echo
echo "============================================================"
echo " STEP 2: APPLY CURATED C PORTABLE REQUIREMENTS"
echo "============================================================"

"$APPLY" \
    "$OUT/b-resolved.config" \
    "$C_REQ" \
    "$OUT/c-requested.config"

#
# Install the same C requirement set as an Armbian custom kernel-config
# extension.  This runs after Armbian's internal policy hook.
#
sudo mkdir -p "$C_EXT_DIR"

sudo install \
    -o "$(id -u)" \
    -g "$(id -g)" \
    -m 0644 \
    "$C_REQ" \
    "$C_EXT_REQ"

cat > "$OUT/${C_EXT_NAME}.sh" <<'EXTENSION'
function custom_kernel_config__900_hwbase_c_parity() {
    local req="${EXTENSION_DIR}/hwbase-c-parity.tsv"
    local symbol value

    [[ -s "$req" ]] ||
        exit_with_error "HWBase C requirements missing" "$req"

    while IFS=$'\t' read -r symbol value; do
        [[ -z "$symbol" ]] && continue
        [[ "$symbol" == \#* ]] && continue

        symbol="${symbol#CONFIG_}"

        case "$value" in
            y)
                opts_y+=("$symbol")
                ;;
            m)
                opts_m+=("$symbol")
                ;;
            n)
                opts_n+=("$symbol")
                ;;
            *)
                opts_val["$symbol"]="$value"
                ;;
        esac
    done < "$req"
}
EXTENSION

sudo install \
    -o "$(id -u)" \
    -g "$(id -g)" \
    -m 0644 \
    "$OUT/${C_EXT_NAME}.sh" \
    "$C_EXT"

#
# Preserve requested config. Armbian's rewrite command may export a
# minimized defconfig back into userpatches.
#
sudo install \
    -o "$(id -u)" \
    -g "$(id -g)" \
    -m 0644 \
    "$OUT/c-requested.config" \
    "$USERPATCH"

echo
echo "============================================================"
echo " STEP 3: NATIVE ARMBIAN/KCONFIG C RESOLUTION"
echo "============================================================"

(
    cd "$ARB"

    ./compile.sh rewrite-kernel-config \
        PREFER_DOCKER=no \
        BOARD="$BOARD" \
        BRANCH="$BRANCH" \
        RELEASE="$RELEASE" \
        BUILD_DESKTOP=no \
        BUILD_MINIMAL=yes \
        KERNEL_BTF=no \
        ENABLE_EXTENSIONS="$C_EXT_NAME" \
        KERNELBRANCH="$KERNEL_PIN"
) 2>&1 | tee "$OUT/c-armbian-rewrite.log"

[[ -s "$KERNEL_TREE/.config" ]] ||
    die "full C .config missing after Armbian resolution"

cp "$KERNEL_TREE/.config" \
    "$OUT/c-resolved.config"

cp "$USERPATCH" \
    "$OUT/c-exported-defconfig.config"

C_KERNEL_HEAD="$(
    git -c safe.directory="$KERNEL_TREE" -C "$KERNEL_TREE" rev-parse HEAD
)"

git -c safe.directory="$KERNEL_TREE" -C "$KERNEL_TREE" status --short \
    > "$OUT/c-kernel-tree-status.txt" || true

echo
echo "===== C KERNEL SOURCE ====="
echo "Expected base commit : $KERNEL_COMMIT"
echo "Kernel tree HEAD     : $C_KERNEL_HEAD"

[[ "$C_KERNEL_HEAD" == "$KERNEL_COMMIT" ]] ||
    die "C kernel source mismatch: expected $KERNEL_COMMIT, got $C_KERNEL_HEAD"

#
# ------------------------------------------------------------
# Audit B -> C
# ------------------------------------------------------------
#

echo
echo "============================================================"
echo " STEP 4: B -> C VALIDATION"
echo "============================================================"

python3 - \
    "$OUT/b-resolved.config" \
    "$OUT/c-resolved.config" \
    "$B_REQ" \
    "$C_REQ" \
    "$OUT" <<'PY'

import json
import sys
from pathlib import Path

b_path = Path(sys.argv[1])
c_path = Path(sys.argv[2])
b_req_path = Path(sys.argv[3])
c_req_path = Path(sys.argv[4])
out = Path(sys.argv[5])


def read_config(path):
    cfg = {}

    for raw in path.read_text(
        errors="replace"
    ).splitlines():

        line = raw.strip()

        if line.startswith("CONFIG_") and "=" in line:
            k, v = line.split("=", 1)
            cfg[k] = v

        elif (
            line.startswith("# CONFIG_")
            and line.endswith(" is not set")
        ):
            k = line[len("# "):].split(
                " is not set", 1
            )[0]

            cfg[k] = "n"

    return cfg


def read_req(path):
    result = {}

    for raw in path.read_text(
        errors="replace"
    ).splitlines():

        line = raw.strip()

        if not line or line.startswith("#"):
            continue

        k, v = line.split("\t", 1)
        result[k] = v

    return result


def functional(actual, wanted):
    #
    # For capability requirements y/m are equivalent.
    # Explicit non-boolean/string/numeric requirements stay exact.
    #
    if wanted in ("y", "m"):
        return actual in ("y", "m")

    return actual == wanted


b = read_config(b_path)
c = read_config(c_path)

b_req = read_req(b_req_path)
c_req = read_req(c_req_path)

#
# B requirement state before and after C.
#
b_baseline_bad = []
b_new_regressions = []

for sym, wanted in sorted(b_req.items()):
    before = b.get(sym, "n")
    after = c.get(sym, "n")

    before_ok = functional(
        before,
        wanted,
    )

    after_ok = functional(
        after,
        wanted,
    )

    if not before_ok:
        b_baseline_bad.append(
            (sym, wanted, before, after)
        )

    elif not after_ok:
        b_new_regressions.append(
            (sym, wanted, before, after)
        )

#
# Pure enabled B -> disabled C regressions.
#
pure_regressions = []

for sym, before in sorted(b.items()):
    if before not in ("y", "m"):
        continue

    after = c.get(sym, "n")

    if after not in ("y", "m"):
        pure_regressions.append(
            (sym, before, after)
        )

#
# C direct requirements.
#
c_ok = []
c_bad = []

for sym, wanted in sorted(c_req.items()):
    actual = c.get(sym, "n")

    if functional(actual, wanted):
        c_ok.append(
            (sym, wanted, actual)
        )
    else:
        c_bad.append(
            (sym, wanted, actual)
        )

#
# Every B -> C change, including mode/value changes.
#
changes = []

for sym in sorted(set(b) | set(c)):
    before = b.get(sym, "n")
    after = c.get(sym, "n")

    if before == after:
        continue

    if before == "n" and after in ("y", "m"):
        cls = "enabled"

    elif (
        before in ("y", "m")
        and after == "n"
    ):
        cls = "disabled"

    elif {before, after} <= {"y", "m"}:
        cls = "mode"

    else:
        cls = "value"

    changes.append(
        (sym, before, after, cls)
    )


def write_tsv(name, rows, header):
    p = out / name

    with p.open("w") as f:
        f.write("\t".join(header) + "\n")

        for row in rows:
            f.write(
                "\t".join(map(str, row))
                + "\n"
            )


write_tsv(
    "b-baseline-unresolved.tsv",
    b_baseline_bad,
    ["symbol", "wanted", "b", "c"],
)

write_tsv(
    "b-new-regressions.tsv",
    b_new_regressions,
    ["symbol", "wanted", "b", "c"],
)

write_tsv(
    "pure-b-enabled-regressions.tsv",
    pure_regressions,
    ["symbol", "b", "c"],
)

write_tsv(
    "c-requirements-failed.tsv",
    c_bad,
    ["symbol", "wanted", "actual"],
)

write_tsv(
    "b-to-c-all-changes.tsv",
    changes,
    ["symbol", "b", "c", "class"],
)

summary = {
    "b_symbols": len(b),
    "c_symbols": len(c),
    "b_requirements": len(b_req),
    "b_baseline_unresolved": len(
        b_baseline_bad
    ),
    "b_new_requirement_regressions": len(
        b_new_regressions
    ),
    "pure_b_enabled_regressions": len(
        pure_regressions
    ),
    "c_requirements": len(c_req),
    "c_requirements_satisfied": len(c_ok),
    "c_requirements_failed": len(c_bad),
    "b_to_c_changes": len(changes),
    "b_to_c_enabled": sum(
        r[3] == "enabled"
        for r in changes
    ),
    "b_to_c_disabled": sum(
        r[3] == "disabled"
        for r in changes
    ),
    "b_to_c_mode": sum(
        r[3] == "mode"
        for r in changes
    ),
    "b_to_c_value": sum(
        r[3] == "value"
        for r in changes
    ),
}

(out / "SUMMARY.json").write_text(
    json.dumps(
        summary,
        indent=2,
        sort_keys=True,
    ) + "\n"
)

print("===== C RESOLUTION AUDIT =====")

for key, value in summary.items():
    print(f"{key:32s}: {value}")

print()

if b_baseline_bad:
    print(
        "B baseline unresolved:"
    )

    for row in b_baseline_bad:
        print("\t".join(row))

    print()

if b_new_regressions:
    print(
        "NEW B requirement regressions:"
    )

    for row in b_new_regressions:
        print("\t".join(row))

    print()

if pure_regressions:
    print(
        "Pure B enabled regressions:"
    )

    for row in pure_regressions:
        print("\t".join(row))

    print()

if c_bad:
    print(
        "Failed C requirements:"
    )

    for row in c_bad:
        print("\t".join(row))

#
# The actual C gate.
#
if (
    b_new_regressions
    or pure_regressions
    or c_bad
):
    raise SystemExit(50)

print("C CONFIGURATION GATE: PASS")
PY

echo
echo "============================================================"
echo " C CONFIGURATION RESOLUTION COMPLETE"
echo "============================================================"

sha256sum \
    "$OUT/b-requested.config" \
    "$OUT/b-resolved.config" \
    "$OUT/c-requested.config" \
    "$OUT/c-resolved.config"

echo
echo "Output:"
echo "$OUT"
