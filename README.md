# VyOS ARM64 Hardware Base

Private build repository for reproducible Armbian hardware-base images used as the hardware/kernel foundation for VyOS ARM64 SBC builds.

## Design

Three profiles are planned:

- **A — `stock`**: Stock Armbian Edge minimal image.
- **B — `vyos-base`**: Armbian Edge plus the defined VyOS ARM64 hardware baseline.
- **C — `vyos-parity`**: Profile B plus kernel/config comparison against an official VyOS Rolling reference.

The repository starts with profile **A fully enabled**. Profiles **B** and **C** are deliberately blocked until the known-good Raspberry Pi system has been inventoried and the baseline/parity policy is committed. This avoids silently producing images that are incorrectly labelled as VyOS-compatible.

## Interactive launcher

The launcher obtains the board list directly from the selected official `armbian/build` git ref. It uses the real Armbian `BOARD=` identifiers and only presents board definitions that advertise `edge`.

```bash
chmod +x armbian-hwbase-build.sh
./armbian-hwbase-build.sh
```

With `fzf` installed you get a searchable board selector. Without it, enter a search term and choose from a numbered list.

Example:

```text
Board search: rock-5

  1) rock-5b
  2) rock-5b-plus

Select board: 1

Image profile:
  A) Stock Armbian Edge
  B) VyOS hardware baseline
  C) VyOS kernel-parity hardware base
```

For profile C the launcher also asks for the VyOS Rolling reference; `latest` is the default.

The launcher resolves the chosen Armbian ref to an **exact git commit** before dispatching GitHub Actions.

## Build command used for profile A

The workflow invokes the official Armbian build framework approximately as follows:

```bash
./compile.sh build \
  BOARD=<exact-armbian-board> \
  BRANCH=edge \
  RELEASE=trixie \
  BUILD_DESKTOP=no \
  BUILD_MINIMAL=yes \
  KERNEL_CONFIGURE=no \
  NETWORKING_STACK=systemd-networkd
```

## Output

A successful profile-A run produces a workflow artifact and, when `publish=true`, a private GitHub release containing:

- compressed/raw Armbian image produced by the framework
- `BUILD-INFO.txt`
- exact `armbian-build-commit.txt`
- `SHA256SUMS`

## Next implementation step

Import the known-good Raspberry Pi hardware reference:

1. complete kernel config
2. every installed kernel module (not only `lsmod`)
3. module metadata and required firmware
4. DTBs and overlays
5. boot files
6. kernel/Armbian packages
7. manually installed package set
8. hardware/kernel identity

That reference will be used to define profile B and the regression/parity rules for profile C.
