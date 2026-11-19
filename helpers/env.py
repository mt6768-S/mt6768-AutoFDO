#!/usr/bin/env python3
from __future__ import annotations

import argparse
import pathlib
import re
import shlex
import sys

KEY_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")


def parse(path: pathlib.Path) -> dict[str, str]:
    pairs: dict[str, str] = {}
    for lineno, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        if "=" not in line:
            raise SystemExit(f"{path}:{lineno}: expected KEY=VALUE, got: {line}")
        key, value = line.split("=", 1)
        key = key.strip()
        if not KEY_RE.fullmatch(key):
            raise SystemExit(f"{path}:{lineno}: invalid variable name: {key!r}")
        pairs[key] = value
    return pairs


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("file", type=pathlib.Path)
    ap.add_argument("--format", choices=("plain", "export"), default="plain")
    ap.add_argument("--get", metavar="KEY", help="print one value and exit")
    args = ap.parse_args()

    if not args.file.is_file():
        print(f"env file not found: {args.file}", file=sys.stderr)
        return 1

    pairs = parse(args.file)

    if args.get:
        if args.get in pairs:
            print(pairs[args.get])
            return 0
        print(f"{args.get} is not set in {args.file}", file=sys.stderr)
        return 1

    for key, value in pairs.items():
        if args.format == "export":
            print(f"export {key}={shlex.quote(value)}")
        else:
            print(f"{key}={value}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
