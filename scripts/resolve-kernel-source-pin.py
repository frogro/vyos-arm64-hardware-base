#!/usr/bin/env python3

import argparse
import re
import shlex
import subprocess
from pathlib import Path


def die(msg):
    raise SystemExit(f"ERROR: {msg}")


def read_info(path):
    result = {}

    for raw in path.read_text(errors="replace").splitlines():
        raw = raw.strip()

        if not raw or "=" not in raw:
            continue

        key, value = raw.split("=", 1)
        result[key] = value

    return result


def ls_remote(url, *refs, allow_fail=False):
    cmd = ["git", "ls-remote", url, *refs]

    p = subprocess.run(
        cmd,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )

    if p.returncode != 0:
        if allow_fail:
            return []

        die(
            "git ls-remote failed:\n"
            + p.stderr.strip()
        )

    rows = []

    for line in p.stdout.splitlines():
        fields = line.split()

        if len(fields) >= 2:
            rows.append((fields[0], fields[1]))

    return rows


def resolve(source, spec):
    if spec.startswith("branch:"):
        name = spec[len("branch:"):]

        if not name:
            die("empty branch name")

        rows = ls_remote(
            source,
            f"refs/heads/{name}",
        )

        if len(rows) != 1:
            die(
                f"cannot resolve branch {name!r}: "
                f"{len(rows)} matches"
            )

        return rows[0][0], f"branch:{name}"

    if spec.startswith("tag:"):
        name = spec[len("tag:"):]

        if not name:
            die("empty tag name")

        #
        # Prefer dereferenced annotated tag.
        #
        rows = ls_remote(
            source,
            f"refs/tags/{name}^{{}}",
            allow_fail=True,
        )

        if rows:
            return rows[0][0], f"tag:{name}"

        rows = ls_remote(
            source,
            f"refs/tags/{name}",
        )

        if len(rows) != 1:
            die(
                f"cannot resolve tag {name!r}: "
                f"{len(rows)} matches"
            )

        return rows[0][0], f"tag:{name}"

    if spec.startswith("commit:"):
        wanted = spec[len("commit:"):].lower()

        if not re.fullmatch(r"[0-9a-f]{7,40}", wanted):
            die(f"invalid commit spec: {spec}")

        if len(wanted) == 40:
            return wanted, spec

        #
        # Resolve abbreviated commit against advertised refs.
        #
        rows = ls_remote(source)

        matches = sorted({
            sha.lower()
            for sha, _ref in rows
            if sha.lower().startswith(wanted)
        })

        if len(matches) != 1:
            die(
                f"cannot uniquely expand commit {wanted}: "
                f"{len(matches)} matches"
            )

        return matches[0], spec

    die(
        "unsupported KERNELBRANCH syntax: "
        + repr(spec)
    )


def rewrite_source_info(path, commit, pinned):
    skip = {
        "kernel_source_commit",
        "kernel_branch_pinned",
    }

    lines = []

    for line in path.read_text(errors="replace").splitlines():
        if "=" in line:
            key = line.split("=", 1)[0]

            if key in skip:
                continue

        lines.append(line)

    lines += [
        f"kernel_source_commit={commit}",
        f"kernel_branch_pinned={pinned}",
    ]

    path.write_text("\n".join(lines) + "\n")


def main():
    ap = argparse.ArgumentParser()

    ap.add_argument(
        "--target-info",
        required=True,
        type=Path,
    )

    ap.add_argument(
        "--output",
        required=True,
        type=Path,
    )

    args = ap.parse_args()

    info = read_info(args.target_info)

    source = info.get("kernel_source", "")
    branch = info.get("kernel_branch", "")

    if not source:
        die("kernel_source missing from target info")

    if not branch:
        die("kernel_branch missing from target info")

    commit, original = resolve(
        source,
        branch,
    )

    if not re.fullmatch(r"[0-9a-f]{40}", commit):
        die(
            "resolved kernel commit is not full SHA1: "
            + commit
        )

    pinned = f"commit:{commit}"

    args.output.parent.mkdir(
        parents=True,
        exist_ok=True,
    )

    with args.output.open("w") as f:
        for key, value in (
            ("KERNEL_SOURCE", source),
            ("KERNEL_BRANCH_ORIGINAL", original),
            ("KERNEL_SOURCE_COMMIT", commit),
            ("KERNEL_BRANCH_PINNED", pinned),
        ):
            f.write(
                f"{key}={shlex.quote(value)}\n"
            )

    rewrite_source_info(
        args.target_info,
        commit,
        pinned,
    )

    print("===== KERNEL SOURCE PIN =====")
    print(f"source   : {source}")
    print(f"original : {branch}")
    print(f"commit   : {commit}")
    print(f"pinned   : {pinned}")
    print(f"output   : {args.output}")


if __name__ == "__main__":
    main()
