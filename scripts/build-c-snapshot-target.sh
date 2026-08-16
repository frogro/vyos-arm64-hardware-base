#!/usr/bin/env bash
set -euo pipefail

ROOT="$(
    cd "$(dirname "${BASH_SOURCE[0]}")/.."
    pwd
)"

die() {
    echo "ERROR: $*" >&2
    exit 1
}

need() {
    command -v "$1" >/dev/null 2>&1 ||
        die "missing command: $1"
}

for cmd in git python3 sha256sum awk find cp date; do
    need "$cmd"
done

if [[ $# -ne 2 ]]; then
    cat >&2 <<USAGE
Usage:
  $0 SNAPSHOT_DIR TARGET_ID

Example:
  $0 \
    analysis/c-snapshots/20260816T113340Z-ea18947bed78 \
    rpi4b__edge__trixie
USAGE
    exit 2
fi

SNAP="$1"
TARGET_ID="$2"

if [[ "$SNAP" != /* ]]; then
    SNAP="$ROOT/$SNAP"
fi

[[ -d "$SNAP" ]] ||
    die "snapshot not found: $SNAP"

ARB="$SNAP/armbian-build"
TARGET="$SNAP/targets/$TARGET_ID"
INFO="$TARGET/SOURCE-INFO.txt"
RES="$TARGET/c-resolution"
IMAGE_OUT="$TARGET/c-image"

[[ -d "$ARB" ]] ||
    die "Armbian snapshot missing: $ARB"

[[ -s "$SNAP/SNAPSHOT-INFO.txt" ]] ||
    die "SNAPSHOT-INFO.txt missing"

[[ -s "$INFO" ]] ||
    die "target SOURCE-INFO.txt missing: $INFO"

value() {
    local key="$1"

    awk -F= -v key="$key" '
        $1 == key {
            sub(/^[^=]*=/, "", $0)
            print
            exit
        }
    ' "$INFO"
}

snapshot_value() {
    local key="$1"

    awk -F= -v key="$key" '
        $1 == key {
            sub(/^[^=]*=/, "", $0)
            print
            exit
        }
    ' "$SNAP/SNAPSHOT-INFO.txt"
}

BOARD="$(value board)"
BRANCH="$(value branch)"
RELEASE="$(value release)"
LINUXCONFIG="$(value linux_config)"
LINUX_SOURCE_DIR="$(value linux_source_dir)"
KERNEL_COMMIT="$(value kernel_source_commit)"
KERNEL_PIN="$(value kernel_branch_pinned)"

ARMBIAN_COMMIT="$(snapshot_value armbian_commit)"
VYOS_VERSION="$(snapshot_value vyos_version)"
VYOS_KERNEL="$(snapshot_value vyos_kernel)"

[[ -n "$BOARD" ]] ||
    die "board missing from target metadata"

[[ -n "$BRANCH" ]] ||
    die "branch missing from target metadata"

[[ -n "$RELEASE" ]] ||
    die "release missing from target metadata"

[[ -n "$LINUXCONFIG" ]] ||
    die "linux_config missing from target metadata"

[[ -n "$LINUX_SOURCE_DIR" ]] ||
    die "linux_source_dir missing from target metadata"

[[ "$KERNEL_COMMIT" =~ ^[0-9a-f]{40}$ ]] ||
    die "invalid kernel source commit: $KERNEL_COMMIT"

[[ "$KERNEL_PIN" == "commit:$KERNEL_COMMIT" ]] ||
    die "kernel pin mismatch: $KERNEL_PIN"

[[ "$ARMBIAN_COMMIT" =~ ^[0-9a-f]{40}$ ]] ||
    die "invalid Armbian commit: $ARMBIAN_COMMIT"

ACTUAL_ARMBIAN="$(
    git \
        -c safe.directory="$ARB" \
        -C "$ARB" \
        rev-parse HEAD
)"

[[ "$ACTUAL_ARMBIAN" == "$ARMBIAN_COMMIT" ]] ||
    die "Armbian snapshot mismatch: expected $ARMBIAN_COMMIT, got $ACTUAL_ARMBIAN"

echo
echo "============================================================"
echo " PROFILE C SNAPSHOT IMAGE BUILD"
echo "============================================================"
echo
echo "Snapshot       : $SNAP"
echo "Target         : $TARGET_ID"
echo "Board          : $BOARD"
echo "Branch         : $BRANCH"
echo "Release        : $RELEASE"
echo "Linux config   : $LINUXCONFIG"
echo "Armbian commit : $ARMBIAN_COMMIT"
echo "Kernel commit  : $KERNEL_COMMIT"
echo "Kernel pin     : $KERNEL_PIN"
echo "VyOS version   : $VYOS_VERSION"
echo "VyOS kernel    : $VYOS_KERNEL"
echo

#
# ------------------------------------------------------------
# STEP 1
# Resolve A -> B -> C and require the configuration gate to PASS.
# ------------------------------------------------------------
#
echo "============================================================"
echo " STEP 1: PROFILE C CONFIGURATION GATE"
echo "============================================================"

"$ROOT/scripts/resolve-c-snapshot-target.sh" \
    "$SNAP" \
    "$TARGET_ID"

C_CONFIG="$RES/c-resolved.config"
B_CONFIG="$RES/b-resolved.config"

[[ -s "$B_CONFIG" ]] ||
    die "resolved B config missing after C gate"

[[ -s "$C_CONFIG" ]] ||
    die "resolved C config missing after C gate"

PRE_C_SHA="$(
    sha256sum "$C_CONFIG" |
        awk '{print $1}'
)"

echo
echo "Validated C config SHA256:"
echo "$PRE_C_SHA"

#
# ------------------------------------------------------------
# STEP 2
# Build the actual image with the same pinned target.
# ------------------------------------------------------------
#
echo
echo "============================================================"
echo " STEP 2: BUILD PROFILE C IMAGE"
echo "============================================================"

LOCAL_MIRROR="${HWBASE_ARMBIAN_MIRROR:-netcup-01.armbian.com/apt}"

mkdir -p "$IMAGE_OUT"

BUILD_MARKER="$RES/image-build-started.marker"
touch "$BUILD_MARKER"

(
    cd "$ARB"

    ./compile.sh build \
        PREFER_DOCKER=no \
        KERNEL_BTF=no \
        KERNEL_CONFIGURE=no \
        BOARD="$BOARD" \
        BRANCH="$BRANCH" \
        RELEASE="$RELEASE" \
        BUILD_DESKTOP=no \
        BUILD_MINIMAL=yes \
        NETWORKING_STACK=systemd-networkd \
        COMPRESS_OUTPUTIMAGE=xz \
        SHARE_LOG=no \
        ENABLE_EXTENSIONS=hwbase-c-parity \
        KERNELBRANCH="$KERNEL_PIN" \
        LOCAL_MIRROR="$LOCAL_MIRROR"
) 2>&1 | tee "$RES/c-image-build.log"

#
# ------------------------------------------------------------
# STEP 3
# Verify that the image build still used the frozen kernel source
# and retained Profile B + C functionality.
# ------------------------------------------------------------
#
echo
echo "============================================================"
echo " STEP 3: POST-BUILD KERNEL VALIDATION"
echo "============================================================"

KERNEL_TREE="$ARB/cache/sources/$LINUX_SOURCE_DIR"

[[ -d "$KERNEL_TREE" ]] ||
    die "kernel source tree missing after build: $KERNEL_TREE"

POST_KERNEL_HEAD="$(
    git \
        -c safe.directory="$KERNEL_TREE" \
        -C "$KERNEL_TREE" \
        rev-parse HEAD
)"

echo "Expected kernel commit : $KERNEL_COMMIT"
echo "Post-build kernel HEAD : $POST_KERNEL_HEAD"

[[ "$POST_KERNEL_HEAD" == "$KERNEL_COMMIT" ]] ||
    die "post-build kernel source mismatch"

POST_CONFIG="$KERNEL_TREE/.config"

[[ -s "$POST_CONFIG" ]] ||
    die "post-build kernel .config missing"

POST_C_SHA="$(
    sha256sum "$POST_CONFIG" |
        awk '{print $1}'
)"

echo "Pre-build C config SHA : $PRE_C_SHA"
echo "Post-build config SHA  : $POST_C_SHA"

python3 - \
    "$ROOT/profiles/vyos-base/kernel-required.tsv" \
    "$ROOT/profiles/vyos-parity/portable-requirements.tsv" \
    "$C_CONFIG" \
    "$POST_CONFIG" <<'PY'
import re
import sys
from pathlib import Path


def config(path):
    out = {}

    for raw in Path(path).read_text().splitlines():
        line = raw.strip()

        m = re.match(
            r"^(CONFIG_[A-Za-z0-9_]+)=(.*)$",
            line,
        )

        if m:
            out[m.group(1)] = m.group(2)
            continue

        m = re.match(
            r"^# (CONFIG_[A-Za-z0-9_]+) is not set$",
            line,
        )

        if m:
            out[m.group(1)] = "n"

    return out


def requirements(path):
    out = {}

    for raw in Path(path).read_text().splitlines():
        line = raw.strip()

        if not line or line.startswith("#"):
            continue

        key, value = line.split("\t", 1)
        out[key] = value

    return out


b_req = requirements(sys.argv[1])
c_req = requirements(sys.argv[2])

expected_c = config(sys.argv[3])
post = config(sys.argv[4])


def get(cfg, key):
    return cfg.get(key, "n")


#
# Profile B non-regression:
# m -> m/y is capability preserving.
# y must remain enabled.
# Non-bool values must match exactly.
#
bad_b = []

for key, wanted in b_req.items():
    actual = get(post, key)

    if wanted == "m":
        good = actual in {"m", "y"}
    elif wanted == "y":
        good = actual == "y"
    else:
        good = actual == wanted

    if not good:
        bad_b.append((key, wanted, actual))


#
# Direct Profile C roots are strict.
#
bad_c = []

for key, wanted in c_req.items():
    actual = get(post, key)

    if actual != wanted:
        bad_c.append((key, wanted, actual))


#
# Nothing that was enabled in resolved C may disappear during
# the image build.  y <-> m remains capability-enabled here.
#
enabled_regressions = []

for key, before in expected_c.items():
    if before not in {"y", "m"}:
        continue

    after = get(post, key)

    if after not in {"y", "m"}:
        enabled_regressions.append(
            (key, before, after)
        )


print("===== POST-BUILD C AUDIT =====")
print(f"B requirements             : {len(b_req)}")
print(f"B requirement regressions  : {len(bad_b)}")
print(f"C requirements             : {len(c_req)}")
print(f"C requirement failures     : {len(bad_c)}")
print(
    "C enabled regressions      : "
    f"{len(enabled_regressions)}"
)

if bad_b:
    print("\nB regressions:")
    for row in bad_b[:100]:
        print("\t".join(row))

if bad_c:
    print("\nC failures:")
    for row in bad_c:
        print("\t".join(row))

if enabled_regressions:
    print("\nC enabled -> disabled:")
    for row in enabled_regressions[:100]:
        print("\t".join(row))

if bad_b or bad_c or enabled_regressions:
    raise SystemExit(60)

print()
print("PROFILE C POST-BUILD GATE: PASS")
PY

#
# ------------------------------------------------------------
# STEP 4
# Collect only files produced by this image build.
# ------------------------------------------------------------
#
echo
echo "============================================================"
echo " STEP 4: COLLECT PROFILE C IMAGE"
echo "============================================================"

mapfile -d '' -t NEW_OUTPUTS < <(
    find "$ARB/output/images" \
        -maxdepth 1 \
        -type f \
        -newer "$BUILD_MARKER" \
        -print0
)

((${#NEW_OUTPUTS[@]} > 0)) ||
    die "no new Armbian image output found"

rm -rf "$IMAGE_OUT"
mkdir -p "$IMAGE_OUT"

for file in "${NEW_OUTPUTS[@]}"; do
    cp -a "$file" "$IMAGE_OUT/"
done

cp "$B_CONFIG" \
    "$IMAGE_OUT/b-resolved.config"

cp "$C_CONFIG" \
    "$IMAGE_OUT/c-resolved.config"

cp "$ROOT/profiles/vyos-base/kernel-required.tsv" \
    "$IMAGE_OUT/b-kernel-required.tsv"

cp "$ROOT/profiles/vyos-parity/portable-requirements.tsv" \
    "$IMAGE_OUT/c-portable-requirements.tsv"

cp "$ROOT/profiles/vyos-parity/root-classification.tsv" \
    "$IMAGE_OUT/c-root-classification.tsv"

cp "$INFO" \
    "$IMAGE_OUT/TARGET-SOURCE-INFO.txt"

cp "$SNAP/SNAPSHOT-INFO.txt" \
    "$IMAGE_OUT/SNAPSHOT-INFO.txt"

cp "$SNAP/SNAPSHOT.json" \
    "$IMAGE_OUT/SNAPSHOT.json"

if [[ -s "$TARGET/kernel-pin.env" ]]; then
    cp "$TARGET/kernel-pin.env" \
        "$IMAGE_OUT/kernel-pin.env"
fi

if [[ -s "$SNAP/vyos/SOURCE-INFO.txt" ]]; then
    cp "$SNAP/vyos/SOURCE-INFO.txt" \
        "$IMAGE_OUT/VYOS-SOURCE-INFO.txt"
fi

HWBASE_COMMIT="$(
    git -C "$ROOT" rev-parse HEAD
)"

cat > "$IMAGE_OUT/BUILD-INFO.txt" <<EOF2
profile=vyos-parity
board=$BOARD
branch=$BRANCH
release=$RELEASE

hardware_base_commit=$HWBASE_COMMIT

armbian_commit=$ARMBIAN_COMMIT
kernel_source_commit=$KERNEL_COMMIT
kernel_branch_pinned=$KERNEL_PIN

vyos_version=$VYOS_VERSION
vyos_kernel=$VYOS_KERNEL

linux_config=$LINUXCONFIG

kernel_config_prebuild_sha256=$PRE_C_SHA
kernel_config_postbuild_sha256=$POST_C_SHA

kernel_configure=no
kernel_btf=no
networking_stack=systemd-networkd
compress_outputimage=xz
armbian_mirror=$LOCAL_MIRROR

built_utc=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
EOF2

(
    cd "$IMAGE_OUT"
    sha256sum \
        $(find . -maxdepth 1 -type f ! -name SHA256SUMS -printf '%f\n' | sort) \
        > SHA256SUMS
)

echo
echo "============================================================"
echo " PROFILE C IMAGE BUILD COMPLETE"
echo "============================================================"
echo
echo "Target              : $TARGET_ID"
echo "Armbian commit      : $ARMBIAN_COMMIT"
echo "Kernel commit       : $KERNEL_COMMIT"
echo "VyOS version        : $VYOS_VERSION"
echo "Pre-build config    : $PRE_C_SHA"
echo "Post-build config   : $POST_C_SHA"
echo
echo "Release assets:"
ls -lh "$IMAGE_OUT"
echo
echo "C_IMAGE_DIR=$IMAGE_OUT"
