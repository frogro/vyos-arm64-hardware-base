#!/usr/bin/env bash
set -euo pipefail

BOARD="${1:?usage: resolve-armbian-target.sh BOARD [BRANCH] [RELEASE] [ARMBIAN_DIR]}"
BRANCH="${2:-edge}"
RELEASE="${3:-trixie}"

CACHE_ROOT="${XDG_CACHE_HOME:-$HOME/.cache}/vyos-armbian-hwbase"
ARMBIAN_DIR="${4:-${ARMBIAN_BUILD_DIR:-$CACHE_ROOT/armbian-build}}"

ROOT="$(
    cd "$(dirname "${BASH_SOURCE[0]}")/.."
    pwd
)"

OUT="${HWBASE_TARGET_OUT:-$ROOT/analysis/targets/$BOARD}"

die() {
    echo "ERROR: $*" >&2
    exit 1
}

git -C "$ARMBIAN_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1 ||
    die "Armbian build tree not found or invalid Git worktree: $ARMBIAN_DIR"

mkdir -p "$OUT"

ARMBIAN_COMMIT="$(
    git -C "$ARMBIAN_DIR" rev-parse HEAD
)"

RAW="$OUT/configdump.raw"
JSON="$OUT/configdump.json"

echo "===== RESOLVE ARMBIAN TARGET ====="
echo "BOARD          : $BOARD"
echo "BRANCH         : $BRANCH"
echo "RELEASE        : $RELEASE"
echo "Armbian dir    : $ARMBIAN_DIR"
echo "Armbian commit : $ARMBIAN_COMMIT"
echo

echo "===== ARMBIAN CONFIGDUMP ====="

(
    cd "$ARMBIAN_DIR"

    CONFIG_DEFS_ONLY=yes \
    ./compile.sh configdump \
        PREFER_DOCKER=no \
        BOARD="$BOARD" \
        BRANCH="$BRANCH" \
        RELEASE="$RELEASE" \
        BUILD_DESKTOP=no \
        BUILD_MINIMAL=yes \
        KERNEL_CONFIGURE=no
) >"$RAW" 2>"$OUT/configdump.stderr"

python3 - "$RAW" "$JSON" "$BOARD" "$BRANCH" "$RELEASE" <<'PY'
import json
import sys
from pathlib import Path

src = Path(sys.argv[1])
dst = Path(sys.argv[2])

requested_board = sys.argv[3]
requested_branch = sys.argv[4]
requested_release = sys.argv[5]

text = src.read_text(errors="replace").strip()

#
# Current Armbian configdump normally emits one JSON object.
# First try that directly.
#
try:
    obj = json.loads(text)
except json.JSONDecodeError:
    #
    # Be tolerant of diagnostics surrounding the JSON.
    #
    decoder = json.JSONDecoder()
    objects = []

    for pos, ch in enumerate(text):
        if ch != "{":
            continue

        try:
            candidate, end = decoder.raw_decode(text[pos:])
        except json.JSONDecodeError:
            continue

        if isinstance(candidate, dict):
            objects.append(candidate)

    obj = None

    #
    # HOST is currently the useful board identifier in configdump.
    #
    for candidate in objects:
        if candidate.get("HOST") == requested_board:
            obj = candidate
            break

    #
    # Fallback: accept a resolved kernel configuration object.
    #
    if obj is None:
        for candidate in objects:
            if (
                candidate.get("LINUXCONFIG")
                and candidate.get("LINUXFAMILY")
                and candidate.get("KERNELSOURCE")
                and candidate.get("KERNELBRANCH")
            ):
                obj = candidate
                break

    if obj is None:
        print(
            "ERROR: no usable Armbian configdump object found",
            file=sys.stderr
        )
        print(text[:4000], file=sys.stderr)
        raise SystemExit(40)

if not isinstance(obj, dict):
    raise SystemExit(
        "ERROR: Armbian configdump root is not a JSON object"
    )

#
# Preserve our requested identity explicitly.  We do not depend on
# Armbian exposing BOARD/BRANCH/RELEASE under specific variable names.
#
obj["_HWBASE_REQUESTED_BOARD"] = requested_board
obj["_HWBASE_REQUESTED_BRANCH"] = requested_branch
obj["_HWBASE_REQUESTED_RELEASE"] = requested_release

dst.write_text(
    json.dumps(
        obj,
        indent=2,
        sort_keys=True
    ) + "\n"
)

print(f"JSON fields : {len(obj)}")
print(
    "Board field : "
    + str(
        obj.get("BOARD")
        or obj.get("HOST")
        or requested_board
    )
)
print(
    "Arch field  : "
    + str(
        obj.get("ARCH")
        or obj.get("ARCHITECTURE")
        or obj.get("KERNEL_SRC_ARCH")
        or ""
    )
)
PY

echo
echo "===== EXTRACT TARGET KERNEL INFORMATION ====="

# configdump/build helpers must never be able to remove our result directory.
mkdir -p "$OUT"

python3 - \
    "$JSON" \
    "$OUT/target.env" \
    "$ARMBIAN_DIR" \
    "$BOARD" \
    "$BRANCH" \
    "$RELEASE" <<'PY'

import json
import shlex
import sys
from pathlib import Path

src = Path(sys.argv[1])
env = Path(sys.argv[2])
armbian = Path(sys.argv[3])

# Be self-contained: make sure the destination directory exists.
env.parent.mkdir(parents=True, exist_ok=True)

requested_board = sys.argv[4]
requested_branch = sys.argv[5]
requested_release = sys.argv[6]

d = json.loads(src.read_text())


def first(*names, default=""):
    for name in names:
        value = d.get(name)

        if value not in (None, ""):
            return value

    return default


values = {
    "BOARD": first(
        "BOARD",
        "HOST",
        default=requested_board,
    ),

    "BOARD_NAME": first(
        "BOARD_NAME",
        default=requested_board,
    ),

    "BOARDFAMILY": first(
        "BOARDFAMILY"
    ),

    "LINUXFAMILY": first(
        "LINUXFAMILY",
        "BOARDFAMILY",
    ),

    "ARCH": first(
        "ARCH",
        "ARCHITECTURE",
        "KERNEL_SRC_ARCH",
    ),

    "BRANCH": first(
        "BRANCH",
        default=requested_branch,
    ),

    "RELEASE": first(
        "RELEASE",
        default=requested_release,
    ),

    "LINUXCONFIG": first(
        "LINUXCONFIG"
    ),

    "KERNELSOURCE": first(
        "KERNELSOURCE"
    ),

    "KERNELBRANCH": first(
        "KERNELBRANCH"
    ),

    "KERNEL_MAJOR_MINOR": first(
        "KERNEL_MAJOR_MINOR"
    ),

    "KERNELPATCHDIR": first(
        "KERNELPATCHDIR"
    ),

    "LINUXSOURCEDIR": first(
        "LINUXSOURCEDIR"
    ),
}

required = [
    "BOARD",
    "LINUXFAMILY",
    "ARCH",
    "LINUXCONFIG",
    "KERNELSOURCE",
    "KERNELBRANCH",
]

missing = [
    key
    for key in required
    if not values.get(key)
]

if missing:
    print(
        "ERROR: configdump missing required resolved fields: "
        + ", ".join(missing),
        file=sys.stderr
    )

    print(
        json.dumps(
            values,
            indent=2,
            sort_keys=True
        ),
        file=sys.stderr
    )

    raise SystemExit(41)

base = (
    armbian
    / "config"
    / "kernel"
    / f"{values['LINUXCONFIG']}.config"
)

if not base.is_file():
    raise SystemExit(
        "ERROR: resolved Armbian kernel config does not exist: "
        + str(base)
    )

values["BASE_CONFIG"] = str(base.resolve())

with env.open("w") as f:
    for key, value in values.items():
        f.write(
            f"{key}={shlex.quote(str(value))}\n"
        )
PY

# shellcheck disable=SC1090
source "$OUT/target.env"

BASE_CONFIG_SHA="$(
    sha256sum "$BASE_CONFIG" |
    awk '{print $1}'
)"

cat > "$OUT/SOURCE-INFO.txt" <<EOF2
board=$BOARD
board_name=$BOARD_NAME
board_family=$BOARDFAMILY
linux_family=$LINUXFAMILY
arch=$ARCH
branch=$BRANCH
release=$RELEASE
linux_config=$LINUXCONFIG
kernel_source=$KERNELSOURCE
kernel_branch=$KERNELBRANCH
kernel_major_minor=$KERNEL_MAJOR_MINOR
kernel_patch_dir=$KERNELPATCHDIR
linux_source_dir=$LINUXSOURCEDIR
base_config=$BASE_CONFIG
base_config_sha256=$BASE_CONFIG_SHA
armbian_commit=$ARMBIAN_COMMIT
EOF2

echo
echo "===== RESOLVED TARGET ====="
cat "$OUT/SOURCE-INFO.txt"

echo
echo "===== BASE CONFIG ====="
echo "$BASE_CONFIG_SHA  $BASE_CONFIG"

echo
echo "Target directory:"
echo "$OUT"
