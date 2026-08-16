#!/usr/bin/env bash
set -euo pipefail

HB_REPO="${HB_REPO:-frogro/vyos-arm64-hardware-base}"
WORKFLOW="${WORKFLOW:-build-hardware-base.yml}"
WORKFLOW_REF="${WORKFLOW_REF:-main}"
ARMBIAN_REF="${ARMBIAN_REF:-main}"
ARMBIAN_REMOTE="${ARMBIAN_REMOTE:-https://github.com/armbian/build.git}"
RELEASE="${RELEASE:-trixie}"
CACHE_ROOT="${XDG_CACHE_HOME:-$HOME/.cache}/vyos-armbian-hwbase"
ARMBIAN_CACHE="$CACHE_ROOT/armbian-build"

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"; }

for cmd in git gh grep sed sort awk mktemp; do need "$cmd"; done

sync_armbian_metadata() {
    mkdir -p "$CACHE_ROOT"
    if [[ ! -d "$ARMBIAN_CACHE/.git" ]]; then
        echo "==> Creating local Armbian metadata cache"
        git clone --filter=blob:none --no-checkout "$ARMBIAN_REMOTE" "$ARMBIAN_CACHE"
    fi
    echo "==> Loading Armbian board definitions from ref: $ARMBIAN_REF"
    git -C "$ARMBIAN_CACHE" fetch --quiet --depth=1 origin "$ARMBIAN_REF"
    git -C "$ARMBIAN_CACHE" checkout --quiet --detach FETCH_HEAD
    ARMBIAN_COMMIT="$(git -C "$ARMBIAN_CACHE" rev-parse HEAD)"
    export ARMBIAN_COMMIT
}

extract_var() {
    local file="$1" var="$2" line value
    line="$(grep -m1 -E "(^|[[:space:]])(declare[[:space:]]+-g[[:space:]]+)?${var}=" "$file" 2>/dev/null || true)"
    [[ -n "$line" ]] || return 1
    value="$(printf '%s\n' "$line" | sed -nE "s/.*${var}=\"([^\"]*)\".*/\1/p")"
    [[ -n "$value" ]] || value="$(printf '%s\n' "$line" | sed -nE "s/.*${var}=([^[:space:]]+).*/\1/p" | tr -d "'\"")"
    [[ -n "$value" ]] || return 1
    printf '%s' "$value"
}

board_status() {
    case "$1" in
        *.conf) printf supported ;;
        *.csc)  printf community ;;
        *.wip)  printf wip ;;
        *.eos)  printf eos ;;
        *.tvb)  printf tvbox ;;
        *)      printf other ;;
    esac
}

discover_edge_boards() {
    local out="$1" file board name targets status
    : > "$out"
    shopt -s nullglob
    for file in "$ARMBIAN_CACHE"/config/boards/*.{conf,csc,wip,eos,tvb}; do
        targets="$(extract_var "$file" KERNEL_TARGET 2>/dev/null || true)"
        [[ ",${targets}," == *",edge,"* ]] || continue
        board="$(basename "$file")"; board="${board%.*}"
        name="$(extract_var "$file" BOARD_NAME 2>/dev/null || true)"
        [[ -n "$name" ]] || name="$board"
        status="$(board_status "$file")"
        printf '%s\t%s\t%s\t%s\n' "$board" "$name" "$status" "$targets" >> "$out"
    done
    shopt -u nullglob
    sort -u -o "$out" "$out"
    [[ -s "$out" ]] || die "no edge-capable boards found at Armbian ref $ARMBIAN_REF"
}

pick_board() {
    local f="$1" query tmp count choice
    if command -v fzf >/dev/null 2>&1; then
        awk -F '\t' '{printf "%-30s | %-42s | %-10s | %s\n",$1,$2,$3,$4}' "$f" |
        fzf --height=80% --border --prompt='Armbian BOARD > ' \
            --header='BOARD | board name | status | kernel targets' |
        awk -F ' *\\| *' '{gsub(/[[:space:]]+$/,"",$1); print $1}'
        return
    fi

    echo >&2
    read -r -p "Board search (e.g. rpi, rock-5, orangepi, radxa; blank = all): " query
    tmp="$(mktemp)"
    if [[ -n "$query" ]]; then grep -i -- "$query" "$f" > "$tmp" || true; else cp "$f" "$tmp"; fi
    count="$(wc -l < "$tmp" | tr -d ' ')"
    [[ "$count" -gt 0 ]] || { rm -f "$tmp"; die "no matching boards"; }
    awk -F '\t' '{printf "%3d) %-28s %-40s [%s]\n",NR,$1,$2,$3}' "$tmp" >&2
    while true; do
        read -r -p "Select board [1-$count]: " choice
        [[ "$choice" =~ ^[0-9]+$ ]] || continue
        (( choice >= 1 && choice <= count )) || continue
        awk -F '\t' -v n="$choice" 'NR==n {print $1}' "$tmp"
        rm -f "$tmp"
        return
    done
}

pick_profile() {
    local c
    echo >&2
    echo "Image profile:" >&2
    echo "  A) Stock Armbian Edge" >&2
    echo "  B) VyOS hardware baseline" >&2
    echo "  C) VyOS kernel-parity hardware base" >&2
    while true; do
        read -r -p "Select profile [A/B/C]: " c
        case "${c^^}" in
            A) printf stock; return ;;
            B) printf vyos-base; return ;;
            C) printf vyos-parity; return ;;
        esac
    done
}

main() {
    sync_armbian_metadata
    board_file="$(mktemp)"
    trap 'rm -f "${board_file:-}"' EXIT
    discover_edge_boards "$board_file"

    echo
    echo "VyOS ARM64 Hardware Base Builder"
    echo "================================"
    echo "Armbian ref    : $ARMBIAN_REF"
    echo "Armbian commit : $ARMBIAN_COMMIT"
    echo "Branch         : edge"
    echo "Release        : $RELEASE"

    BOARD="$(pick_board "$board_file")"
    [[ -n "$BOARD" ]] || die "no board selected"
    LINE="$(awk -F '\t' -v b="$BOARD" '$1==b {print;exit}' "$board_file")"
    BOARD_NAME="$(printf '%s\n' "$LINE" | awk -F '\t' '{print $2}')"
    STATUS="$(printf '%s\n' "$LINE" | awk -F '\t' '{print $3}')"
    PROFILE="$(pick_profile)"

    VYOS_VERSION=latest

    echo
    echo "Selected build"
    echo "--------------"
    echo "Armbian BOARD  : $BOARD"
    echo "Board name     : $BOARD_NAME"
    echo "Board status   : $STATUS"
    echo "Profile        : $PROFILE"
    echo "Branch         : edge"
    echo "Release        : $RELEASE"
    if [[ "$PROFILE" == vyos-parity ]]; then
        echo "Armbian source  : current main (frozen by GitHub)"
        echo "VyOS reference : current official Rolling (frozen by GitHub)"
        echo "Publishing     : normal GitHub release"
    else
        echo "Armbian commit : $ARMBIAN_COMMIT"
    fi
    echo

    read -r -p "Trigger GitHub Actions build now? [y/N]: " ans
    [[ "${ans,,}" == y || "${ans,,}" == yes ]] || { echo "Cancelled."; exit 0; }

    gh workflow run "$WORKFLOW" \
        --repo "$HB_REPO" \
        --ref "$WORKFLOW_REF" \
        -f board="$BOARD" \
        -f profile="$PROFILE" \
        -f branch=edge \
        -f release="$RELEASE" \
        -f armbian_ref="$ARMBIAN_COMMIT" \
        -f vyos_version="$VYOS_VERSION" \
        -f publish=true

    echo
    echo "Build dispatched."
    echo "Follow with:"
    echo "gh run list --repo $HB_REPO --workflow $WORKFLOW --limit 5"
}

main "$@"
