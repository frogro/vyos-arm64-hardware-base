#!/usr/bin/env bash
set -euo pipefail

ROOT="$(
    cd "$(dirname "${BASH_SOURCE[0]}")/.."
    pwd
)"

CACHE_ROOT="${XDG_CACHE_HOME:-$HOME/.cache}/vyos-armbian-hwbase"
ARMBIAN_BASE="${ARMBIAN_BUILD_DIR:-$CACHE_ROOT/armbian-build}"
SNAPSHOT_ROOT="${HWBASE_SNAPSHOT_ROOT:-$ROOT/analysis/c-snapshots}"

die() {
    echo "ERROR: $*" >&2
    exit 1
}

need() {
    command -v "$1" >/dev/null 2>&1 ||
        die "missing command: $1"
}

for cmd in git python3 date sha256sum; do
    need "$cmd"
done

[[ -x "$ROOT/scripts/fetch-vyos-rolling-reference.sh" ]] ||
    die "missing fetch-vyos-rolling-reference.sh"

[[ -x "$ROOT/scripts/resolve-armbian-target.sh" ]] ||
    die "missing resolve-armbian-target.sh"

[[ -d "$ARMBIAN_BASE/.git" ]] ||
    die "Armbian repository not found: $ARMBIAN_BASE"

if [[ $# -eq 0 ]]; then
    cat >&2 <<EOF2
Usage:
  $0 BOARD[:BRANCH[:RELEASE]] [...]

Examples:
  $0 rpi4b
  $0 rpi4b:edge:trixie
  $0 rpi4b:edge:trixie another-board:edge:trixie
EOF2
    exit 2
fi

mkdir -p "$CACHE_ROOT" "$SNAPSHOT_ROOT"

#
# Prevent two snapshot preparations from modifying the Armbian
# repository/worktree list simultaneously.
#
if command -v flock >/dev/null 2>&1; then
    exec 9>"$CACHE_ROOT/.snapshot.lock"

    flock -n 9 ||
        die "another snapshot preparation is already running"
fi

echo "===== C SNAPSHOT: UPDATE ARMBIAN ====="
echo "Base repository: $ARMBIAN_BASE"
echo

ORIGIN_URL="$(
    git -C "$ARMBIAN_BASE" remote get-url origin
)"

echo "origin: $ORIGIN_URL"

#
# Fetch without modifying the user's checked-out branch.
#
git -C "$ARMBIAN_BASE" fetch \
    --no-tags \
    --prune \
    origin \
    '+refs/heads/main:refs/remotes/origin/main'

ARMBIAN_COMMIT="$(
    git -C "$ARMBIAN_BASE" \
        rev-parse refs/remotes/origin/main
)"

ARMBIAN_SHORT="${ARMBIAN_COMMIT:0:12}"

echo "Frozen Armbian commit: $ARMBIAN_COMMIT"

RUN_TIME="$(
    date -u '+%Y%m%dT%H%M%SZ'
)"

RUN_ID="${RUN_TIME}-${ARMBIAN_SHORT}"
RUN="$SNAPSHOT_ROOT/$RUN_ID"

if [[ -e "$RUN" ]]; then
    RUN="${RUN}-${BASHPID}"
fi

mkdir -p "$RUN"

ARMBIAN_SNAPSHOT="$RUN/armbian-build"

echo
echo "===== CREATE FROZEN ARMBIAN WORKTREE ====="

git -C "$ARMBIAN_BASE" worktree add \
    --detach \
    "$ARMBIAN_SNAPSHOT" \
    "$ARMBIAN_COMMIT"

ACTUAL="$(
    git -C "$ARMBIAN_SNAPSHOT" rev-parse HEAD
)"

[[ "$ACTUAL" == "$ARMBIAN_COMMIT" ]] ||
    die "snapshot commit mismatch"

echo "Worktree: $ARMBIAN_SNAPSHOT"
echo "Commit  : $ACTUAL"

echo
echo "===== FETCH AND FREEZE CURRENT VYOS ====="

VYOS_DIR="$RUN/vyos"

"$ROOT/scripts/fetch-vyos-rolling-reference.sh" \
    "$VYOS_DIR"

INFO="$VYOS_DIR/SOURCE-INFO.txt"

[[ -s "$INFO" ]] ||
    die "VyOS SOURCE-INFO.txt missing"

get_info() {
    local key="$1"

    awk -F= -v key="$key" '
        $1 == key {
            sub(/^[^=]*=/, "", $0)
            print
            exit
        }
    ' "$INFO"
}

VYOS_VERSION="$(get_info vyos_version)"
VYOS_KERNEL="$(get_info kernel_release)"
VYOS_CONFIG_SHA="$(get_info kernel_config_sha256)"
VYOS_ISO_SHA="$(get_info iso_sha256)"

[[ -n "$VYOS_VERSION" ]] ||
    die "VyOS version unresolved"

[[ -n "$VYOS_CONFIG_SHA" ]] ||
    die "VyOS config SHA unresolved"

echo
echo "===== RESOLVE ALL TARGETS AGAINST SAME SNAPSHOT ====="

mkdir -p "$RUN/targets"

TARGET_MANIFEST="$RUN/targets.tsv"

printf \
    'board\tbranch\trelease\tlinux_family\tarch\tlinux_config\tbase_config_sha256\tkernel_source_commit\n' \
    > "$TARGET_MANIFEST"

for SPEC in "$@"; do

    IFS=: read -r BOARD BRANCH RELEASE EXTRA <<< "$SPEC"

    [[ -n "${BOARD:-}" ]] ||
        die "invalid target specification: $SPEC"

    [[ -z "${EXTRA:-}" ]] ||
        die "too many ':' fields in target: $SPEC"

    BRANCH="${BRANCH:-edge}"
    RELEASE="${RELEASE:-trixie}"

    SAFE_SPEC="$(
        printf '%s__%s__%s' \
            "$BOARD" "$BRANCH" "$RELEASE" |
        tr -c 'A-Za-z0-9_.-' '_'
    )"

    TARGET_DIR="$RUN/targets/$SAFE_SPEC"

    echo
    echo "----------------------------------------------------------------"
    echo "Target : $BOARD"
    echo "Branch : $BRANCH"
    echo "Release: $RELEASE"
    echo "----------------------------------------------------------------"

    HWBASE_TARGET_OUT="$TARGET_DIR" \
        "$ROOT/scripts/resolve-armbian-target.sh" \
        "$BOARD" \
        "$BRANCH" \
        "$RELEASE" \
        "$ARMBIAN_SNAPSHOT"

    TARGET_INFO="$TARGET_DIR/SOURCE-INFO.txt"

    [[ -s "$TARGET_INFO" ]] ||
        die "target SOURCE-INFO missing: $BOARD"

    echo
    echo "===== FREEZE TARGET KERNEL SOURCE ====="

    python3 "$ROOT/scripts/resolve-kernel-source-pin.py" \
        --target-info "$TARGET_INFO" \
        --output "$TARGET_DIR/kernel-pin.env"

    value() {
        local key="$1"

        awk -F= -v key="$key" '
            $1 == key {
                sub(/^[^=]*=/, "", $0)
                print
                exit
            }
        ' "$TARGET_INFO"
    }

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$BOARD" \
        "$BRANCH" \
        "$RELEASE" \
        "$(value linux_family)" \
        "$(value arch)" \
        "$(value linux_config)" \
        "$(value base_config_sha256)" \
        "$(value kernel_source_commit)" \
        >> "$TARGET_MANIFEST"

done

echo
echo "===== WRITE RUN MANIFEST ====="

cat > "$RUN/SNAPSHOT-INFO.txt" <<EOF2
snapshot_format=1
run_id=$RUN_ID
created_utc=$RUN_TIME

armbian_origin=$ORIGIN_URL
armbian_commit=$ARMBIAN_COMMIT
armbian_worktree=$ARMBIAN_SNAPSHOT

vyos_version=$VYOS_VERSION
vyos_kernel=$VYOS_KERNEL
vyos_config_sha256=$VYOS_CONFIG_SHA
vyos_iso_sha256=$VYOS_ISO_SHA
vyos_reference_dir=$VYOS_DIR

target_count=$#
EOF2

#
# Machine-readable JSON manifest as well.
#
python3 - \
    "$RUN/SNAPSHOT-INFO.txt" \
    "$TARGET_MANIFEST" \
    "$RUN/SNAPSHOT.json" <<'PY'
import csv
import json
import sys
from pathlib import Path

info_path = Path(sys.argv[1])
targets_path = Path(sys.argv[2])
out = Path(sys.argv[3])

info = {}

for line in info_path.read_text().splitlines():
    line = line.strip()

    if not line or "=" not in line:
        continue

    key, value = line.split("=", 1)
    info[key] = value

with targets_path.open() as f:
    targets = list(
        csv.DictReader(
            f,
            delimiter="\t",
        )
    )

data = {
    "snapshot": info,
    "targets": targets,
}

out.write_text(
    json.dumps(
        data,
        indent=2,
        sort_keys=True
    ) + "\n"
)
PY

echo
echo "===== C SNAPSHOT READY ====="
echo

cat "$RUN/SNAPSHOT-INFO.txt"

echo
echo "Targets:"
column -ts $'\t' "$TARGET_MANIFEST" 2>/dev/null ||
    cat "$TARGET_MANIFEST"

echo
echo "Snapshot directory:"
echo "$RUN"

echo
echo "SNAPSHOT_DIR=$RUN"
