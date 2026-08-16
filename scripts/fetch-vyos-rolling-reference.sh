#!/usr/bin/env bash
set -euo pipefail

OUT="${1:-analysis/vyos-current}"

VERSION_JSON_URL="${VYOS_VERSION_JSON_URL:-https://raw.githubusercontent.com/vyos/vyos-nightly-build/rolling/version.json}"

# Official VyOS minisign public key from the VyOS documentation.
VYOS_MINISIGN_PUBKEY="${VYOS_MINISIGN_PUBKEY:-RWSIhkR/dkM2DSaBRniv/bbbAf8hmDqdbOEmgXkf1RxRoxzodgKcDyGq}"

KEEP_ISO="${KEEP_ISO:-0}"

die() {
    echo "ERROR: $*" >&2
    exit 1
}

need() {
    command -v "$1" >/dev/null 2>&1 ||
        die "missing command: $1"
}

for cmd in curl python3 sha256sum xorriso unsquashfs minisign; do
    need "$cmd"
done

mkdir -p "$OUT"
OUT="$(realpath "$OUT")"

TMP="$(mktemp -d)"
cleanup() {
    rm -rf "$TMP"
}
trap cleanup EXIT

echo "===== VYOS CURRENT REFERENCE ====="
echo "version pointer: $VERSION_JSON_URL"
echo

curl \
    --fail \
    --silent \
    --show-error \
    --location \
    --retry 5 \
    --retry-delay 2 \
    "$VERSION_JSON_URL" \
    -o "$TMP/version.json"

python3 - "$TMP/version.json" "$TMP/reference.env" <<'PY'
import json
import shlex
import sys
from pathlib import Path

src = Path(sys.argv[1])
dst = Path(sys.argv[2])

data = json.loads(src.read_text())

if not isinstance(data, list) or not data:
    raise SystemExit("ERROR: unexpected VyOS version.json format")

entry = data[0]

for key in ("url", "version", "timestamp"):
    if key not in entry or not entry[key]:
        raise SystemExit(f"ERROR: version.json missing {key}")

url = entry["url"]
version = entry["version"]
timestamp = entry["timestamp"]

if not url.startswith("https://github.com/vyos/vyos-nightly-build/"):
    raise SystemExit(
        "ERROR: unexpected VyOS download host/path: " + url
    )

if not url.endswith(".iso"):
    raise SystemExit("ERROR: VyOS reference is not an ISO")

with dst.open("w") as f:
    f.write(f"VYOS_URL={shlex.quote(url)}\n")
    f.write(f"VYOS_VERSION={shlex.quote(version)}\n")
    f.write(f"VYOS_TIMESTAMP={shlex.quote(timestamp)}\n")
PY

# shellcheck disable=SC1090
source "$TMP/reference.env"

ISO_NAME="${VYOS_URL##*/}"
ISO="$OUT/$ISO_NAME"
SIG="$OUT/$ISO_NAME.minisig"

echo "VyOS version : $VYOS_VERSION"
echo "Timestamp    : $VYOS_TIMESTAMP"
echo "ISO          : $ISO_NAME"
echo

echo "===== DOWNLOAD ISO ====="

curl \
    --fail \
    --show-error \
    --location \
    --retry 5 \
    --retry-delay 2 \
    "$VYOS_URL" \
    -o "$ISO.part"

mv "$ISO.part" "$ISO"

echo
echo "===== DOWNLOAD SIGNATURE ====="

curl \
    --fail \
    --silent \
    --show-error \
    --location \
    --retry 5 \
    --retry-delay 2 \
    "${VYOS_URL}.minisig" \
    -o "$SIG"

echo
echo "===== VERIFY OFFICIAL SIGNATURE ====="

minisign \
    -V \
    -P "$VYOS_MINISIGN_PUBKEY" \
    -m "$ISO" \
    -x "$SIG"

ISO_SHA="$(
    sha256sum "$ISO" |
    awk '{print $1}'
)"

ISO_SIZE="$(
    stat -c '%s' "$ISO"
)"

echo
echo "ISO size   : $ISO_SIZE"
echo "ISO SHA256 : $ISO_SHA"

echo
echo "===== EXTRACT SQUASHFS FROM ISO ====="

SQFS="$TMP/filesystem.squashfs"
ISO_VERSION_JSON="$TMP/iso-version.json"

xorriso \
    -osirrox on \
    -indev "$ISO" \
    -extract /live/filesystem.squashfs "$SQFS" \
    >/dev/null 2>&1

[[ -s "$SQFS" ]] ||
    die "filesystem.squashfs extraction failed"

# Cross-check the version metadata embedded in the ISO.
xorriso \
    -osirrox on \
    -indev "$ISO" \
    -extract /version.json "$ISO_VERSION_JSON" \
    >/dev/null 2>&1 || true

echo
echo "===== FIND VYOS KERNEL CONFIG ====="

CFG_PATH="$(
    unsquashfs -l "$SQFS" |
    sed -n 's#^squashfs-root/##p' |
    grep '^boot/config-' |
    head -1
)"

[[ -n "$CFG_PATH" ]] ||
    die "official VyOS kernel config not found"

KERNEL_RELEASE="${CFG_PATH#boot/config-}"

echo "Kernel config : $CFG_PATH"
echo "Kernel release: $KERNEL_RELEASE"

CONFIG="$OUT/official-vyos-kernel.config"

unsquashfs \
    -cat "$SQFS" "$CFG_PATH" \
    > "$CONFIG"

[[ -s "$CONFIG" ]] ||
    die "extracted VyOS kernel config is empty"

CONFIG_SHA="$(
    sha256sum "$CONFIG" |
    awk '{print $1}'
)"

CONFIG_SYMBOLS="$(
    grep -Ec '^(CONFIG_|# CONFIG_.* is not set)' "$CONFIG"
)"

echo
echo "===== EXTRACTED KERNEL REFERENCE ====="
echo "VyOS version : $VYOS_VERSION"
echo "Kernel       : $KERNEL_RELEASE"
echo "Config SHA   : $CONFIG_SHA"
echo "Symbols      : $CONFIG_SYMBOLS"

cp "$TMP/version.json" "$OUT/latest-version.json"

if [[ -s "$ISO_VERSION_JSON" ]]; then
    cp "$ISO_VERSION_JSON" "$OUT/iso-version.json"
fi

cat > "$OUT/SOURCE-INFO.txt" <<EOF2
vyos_version=$VYOS_VERSION
vyos_timestamp=$VYOS_TIMESTAMP
vyos_url=$VYOS_URL
iso_name=$ISO_NAME
iso_size=$ISO_SIZE
iso_sha256=$ISO_SHA
kernel_release=$KERNEL_RELEASE
kernel_config_path=$CFG_PATH
kernel_config_sha256=$CONFIG_SHA
kernel_config_symbols=$CONFIG_SYMBOLS
version_pointer=$VERSION_JSON_URL
EOF2

printf '%s\n' "$VYOS_VERSION" \
    > "$OUT/vyos-version.txt"

printf '%s\n' "$KERNEL_RELEASE" \
    > "$OUT/vyos-kernel-release.txt"

printf '%s\n' "$ISO_SHA" \
    > "$OUT/vyos-iso-sha256.txt"

printf '%s\n' "$CONFIG_SHA" \
    > "$OUT/vyos-config-sha256.txt"

if [[ "$KEEP_ISO" != 1 ]]; then
    rm -f "$ISO" "$SIG"
fi

echo
echo "===== RESULT ====="
cat "$OUT/SOURCE-INFO.txt"

echo
echo "Reference directory:"
echo "$OUT"
