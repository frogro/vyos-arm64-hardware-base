# VyOS ARM64 Hardware Base

Private build repository for reproducible Armbian hardware-base images used as the hardware/kernel foundation for VyOS ARM64 SBC builds.

The goal is not to convert an existing VyOS amd64 image to ARM64. Instead, this repository provides reproducible ARM64 board/kernel/boot foundations which can be combined with a VyOS ARM64 userspace build.

The project deliberately separates:

- board and SoC hardware support
- portable VyOS-related kernel functionality
- official VyOS Rolling kernel-parity analysis

This makes it possible to support multiple ARM64 SBC families without copying a finished kernel `.config` from one architecture or board to another.

---

## Design overview

Three hardware-base profiles are defined:

- **A — `stock`**  
  Stock Armbian Edge hardware base.

- **B — `vyos-base`**  
  Stock Armbian Edge plus the functional hardware/kernel baseline derived from the known-good VyOS Raspberry Pi reference.

- **C — `vyos-parity`**  
  Profile B plus the portable functional kernel delta required to approach the current official VyOS Rolling kernel configuration.

Conceptually:

```text
                         Known-good VyOS Pi
                                |
                                | functional delta
                                v
Stock Armbian Edge  ----------> B ----------> C
        A                         ^             ^
                                  |             |
                           VyOS hardware    portable delta
                              baseline      from official
                                            VyOS Rolling
                                               kernel
```

The central rule is:

> Transfer functionality, not finished kernel configuration files.

A Raspberry Pi `.config` is not copied to Rockchip, and an amd64 VyOS `.config` is not copied to ARM64.

Each target kernel family resolves the required functionality using its own Kconfig symbols, dependencies and hardware-specific drivers.

---

## Profile A — Stock Armbian Edge

Profile A is the board's normal Armbian Edge hardware foundation and serves as the baseline for all comparisons.

It includes the board-specific:

- kernel
- kernel modules
- firmware
- DTBs and overlays
- bootloader
- boot configuration
- Armbian board support

The workflow currently builds minimal images using the official Armbian build framework with settings approximately equivalent to:

```bash
./compile.sh build \
  PREFER_DOCKER=no \
  KERNEL_BTF=no \
  BOARD=<exact-armbian-board> \
  BRANCH=edge \
  RELEASE=trixie \
  BUILD_DESKTOP=no \
  BUILD_MINIMAL=yes \
  KERNEL_CONFIGURE=no \
  NETWORKING_STACK=systemd-networkd \
  COMPRESS_OUTPUTIMAGE=xz \
  SHARE_LOG=no
```

`KERNEL_BTF=no` is currently used as a build/reliability setting. It is not intended to define an additional VyOS functional kernel delta.

---

## Profile B — VyOS hardware baseline

Profile B is derived from the known-good Raspberry Pi VyOS hardware base.

The derivation starts with:

```text
Factory Stock Armbian Edge / Raspberry Pi
                  |
                  | compare
                  v
Known-good VyOS Raspberry Pi hardware base
```

The complete functional difference is measured first.

We do **not** begin by manually selecting only features that appear to be useful for a router.

Instead:

1. Compare Stock A/Pi with the known-good Golden Pi.
2. Treat all functionality added by Golden as relevant initially.
3. Remove only clearly:
   - Raspberry Pi / BCM / RP1-specific functionality
   - other board/SoC/architecture-specific functionality
   - compiler/build/debug/Kconfig metadata without functional value
4. Treat everything remaining as the candidate VyOS hardware baseline.
5. Resolve that functionality separately for every target kernel family.

The current Raspberry Pi comparison produced:

```text
Kernel: 7.1.8-edge-bcm2711

Stock config symbols:        8100
Golden config symbols:       8844

Changed total:                849
Golden added/enabled:         841
Golden disabled:                1
Value changed:                  7

Stock unique modules:        2572
Golden unique modules:       3055
Golden additional modules:    487
```

The 841 Golden-added Kconfig requirements are stored in:

```text
profiles/vyos-base/kernel-required.tsv
```

Their derivation and reference hashes are documented in:

```text
profiles/vyos-base/SOURCE-INFO.txt
```

The profile-B requirements are applied to the normal Armbian kernel-family configuration before Kconfig resolves the final configuration.

For Raspberry Pi this currently means:

```text
Armbian linux-bcm2711-edge config
             |
             | + 841 B requirements
             v
requested B pre-config
             |
             | Kconfig / olddefconfig
             v
final Raspberry Pi B kernel config
```

The final generated kernel configuration, not merely the requested pre-config, must be validated.

---

## Porting Profile B to another board

Profile B transfers functionality, not the Raspberry Pi `.config`.

For each B requirement on a new target such as `rockchip64-edge`, the following resolution rules apply:

```text
Function already present in Stock A
    -> no change

Same Kconfig symbol exists but is disabled
    -> enable it

Same function uses another target-specific symbol or driver
    -> use the target-specific counterpart

Function needs target-specific dependencies
    -> add the required dependencies

Function is not available in that target kernel
    -> document as unavailable

Function is irrelevant to the target hardware
    -> do not force it
```

Where possible, this resolution should be performed once per kernel family rather than duplicated for every individual SBC.

Examples:

```text
bcm2711-edge
rockchip64-edge
```

This means that a capability already present in Stock A/E52C must not be added again merely because it appeared in the Raspberry Pi Golden delta.

For example, Stock Armbian Edge for the Radxa E52C already contains:

```text
CONFIG_R8169=m
```

and the final image contains:

```text
/usr/lib/modules/7.1.8-edge-rockchip64/kernel/drivers/net/ethernet/realtek/r8169.ko
```

Therefore Realtek RTL8125 support is already part of Profile A on the E52C and does not need to be introduced by Profile B.

---

## Profile C — VyOS kernel-parity hardware base

Profile C builds on the **validated final Profile B kernel**.

It is not generated directly from the official VyOS amd64 `.config`.

Conceptually:

```text
Stock A
   |
   | Golden functional delta
   v
Profile B
   |
   | portable functional delta from official VyOS Rolling kernel
   v
Profile C
```

The procedure is:

1. Build and validate Profile B.
2. Capture the final B kernel configuration.
3. Obtain the kernel configuration from the selected official VyOS Rolling reference.
4. Compare final B against the official VyOS kernel configuration.
5. Classify every relevant difference.
6. Transfer only portable functionality.
7. Resolve symbols and dependencies against the target ARM64 kernel family.
8. Run Kconfig normally.
9. Validate the final generated C configuration.

Differences from the official VyOS kernel are classified approximately as:

```text
portable-functional
architecture-specific
board-specific
compiler/build-noise
mode-review
disable-review
target-counterpart
unavailable
not-applicable
```

Examples:

```text
VyOS networking feature missing in B
    -> portable candidate for C

CONFIG_X86_* option
    -> amd64/x86 specific, do not transfer

Compiler version metadata
    -> build noise, do not transfer

Function renamed in newer ARM kernel
    -> use the target kernel counterpart

Function absent from the target kernel
    -> document unavailable
```

Profile C therefore represents **functional kernel parity where meaningful**, not byte-for-byte or symbol-for-symbol parity with the amd64 VyOS kernel.

Kernel configuration parity also does not imply source-code or VyOS kernel-patch parity. Source patches must be evaluated separately when relevant.

---

## Validation order

The A/B/C method is intentionally being validated completely on one platform before transferring it to another kernel family.

The fixed validation sequence is:

```text
Raspberry Pi
============

A/Pi
 |
 | Golden functional delta
 v
B/Pi
 |
 | official VyOS Rolling portable kernel delta
 v
C/Pi
 |
 v
validate complete A/B/C method


then:


Radxa E52C
==========

A/E52C
 |
 | resolve B functionality against rockchip64-edge
 v
B/E52C
 |
 | resolve C functionality against rockchip64-edge
 v
C/E52C
 |
 v
validate
```

Therefore the implementation order is:

1. A/Pi
2. A/E52C
3. derive A/Pi -> Golden delta
4. B/Pi
5. validate B/Pi
6. derive B/Pi -> official VyOS Rolling kernel delta
7. C/Pi
8. validate C/Pi
9. resolve B requirements for `rockchip64-edge`
10. B/E52C
11. validate B/E52C
12. resolve C requirements for `rockchip64-edge`
13. C/E52C
14. validate C/E52C

This prevents board-porting problems and VyOS-parity problems from being mixed together during development.

---

## Current implementation status

Current status:

```text
A / Raspberry Pi    implemented and validated
A / Radxa E52C      implemented and validated

Golden Pi inventory completed
A/Pi -> Golden comparison completed
Profile B requirement catalog generated

B / Raspberry Pi    implemented; build/validation in progress
C / Raspberry Pi    next after B/Pi validation

B / Radxa E52C      after complete Pi A/B/C validation
C / Radxa E52C      after B/E52C validation
```

Profile B is currently enabled only for the Raspberry Pi reference target.

Profile C remains blocked until the final B/Pi image has been validated and the official VyOS Rolling parity delta has been classified.

Other boards must not be enabled for B or C until their target-specific requirement resolution has been performed.

---

## Reproducibility

Armbian references must be resolved to exact git commits before a reference build is dispatched.

The current reference builds were made from:

```text
Armbian build commit:
244984be3a64e34133c3b4fbe09acaf43b1b903b
```

For reproducible comparison builds, invoke the launcher with an explicit Armbian ref:

```bash
ARMBIAN_REF=244984be3a64e34133c3b4fbe09acaf43b1b903b \
./armbian-hwbase-build.sh
```

The launcher must then report:

```text
Armbian ref    : 244984be3a64e34133c3b4fbe09acaf43b1b903b
Armbian commit : 244984be3a64e34133c3b4fbe09acaf43b1b903b
```

Using `main` is useful for discovering current Armbian board definitions, but reference A/B/C comparisons must use an explicitly pinned commit.

---

## Interactive launcher

The launcher obtains board definitions directly from the selected official `armbian/build` git ref.

It uses the actual Armbian `BOARD=` identifiers and only presents board definitions supporting the Edge branch.

Run:

```bash
chmod +x armbian-hwbase-build.sh
./armbian-hwbase-build.sh
```

With `fzf` installed, a searchable selector can be used. Otherwise the launcher provides a text search and numbered board list.

Example:

```text
Board search: radxa

  1) radxa-e52c
  ...

Select board: 1

Image profile:
  A) Stock Armbian Edge
  B) VyOS hardware baseline
  C) VyOS kernel-parity hardware base
```

Profile C also carries a VyOS Rolling reference so that its parity source can be identified reproducibly.

The workflow itself is dispatched from:

```text
.github/workflows/build-hardware-base.yml
```

---

## Repository structure

Important files currently include:

```text
.github/workflows/
    build-hardware-base.yml

profiles/
    vyos-base/
        kernel-required.tsv
        SOURCE-INFO.txt

scripts/
    apply-kconfig-requirements.py
    classify-b-source.py
    compare-pi-stock-golden.py

armbian-hwbase-build.sh
```

Generated analysis data and generated kernel pre-configs are intentionally not treated as authoritative source files.

Examples:

```text
analysis/
profiles/vyos-base/generated/
```

The authoritative inputs are the requirement catalogs, provenance information, exact source revisions and reference hashes.

Large local reference images and hardware inventory archives are also excluded from normal git history.

---

## Reference data

The known-good Raspberry Pi reference includes enough information to compare the complete hardware/kernel foundation rather than only currently loaded modules.

The collected reference includes:

- complete running kernel config
- all installed kernel modules
- module metadata
- firmware requirements
- DTBs and overlays
- boot configuration
- kernel/Armbian package information
- manually installed package set
- kernel and hardware identity

This Golden reference is used to derive Profile B.

The official VyOS Rolling kernel reference is used separately to derive Profile C.

These two reference roles must not be mixed:

```text
Golden Pi
    -> defines the proven VyOS ARM64 hardware baseline (B)

Official VyOS Rolling kernel
    -> defines additional portable kernel-parity functionality (C)
```

---

## Output and release metadata

A successful build produces an image generated by the official Armbian build framework.

Published hardware-base releases contain the relevant image plus reproducibility metadata such as:

```text
BUILD-INFO.txt
armbian-build-commit.txt
SHA256SUMS
```

Profile-specific builds may additionally include the exact requirement catalog and requested kernel pre-config used for that build.

The final generated kernel configuration inside the image remains the authoritative result of Kconfig resolution.

---

## Project invariants

The following rules should remain true as support for additional ARM64 boards is added:

1. Profile A remains the board's normal Armbian Edge hardware base.
2. Profile B is derived from the complete functional Golden-Pi delta.
3. Profile C always builds on validated B.
4. Finished Raspberry Pi kernel configurations are never copied blindly to other boards.
5. The official VyOS amd64 kernel configuration is never copied blindly to ARM64.
6. Board-specific functionality remains owned by the target board/kernel family.
7. Portable functionality is resolved through target Kconfig symbols and dependencies.
8. Unavailable or non-applicable functionality is documented rather than silently forced.
9. Final generated configs and modules are validated after every profile build.
10. Reproducible comparison builds use exact source commits.

The intended result is a reusable ARM64 hardware-base factory where support for a new SBC is added by resolving well-defined functional requirements against that board's native Armbian hardware stack.
