#!/usr/bin/env python3
import argparse, pathlib, re, sys

CONFIG_PATH = pathlib.Path("out/.config")

def main():
    parser = argparse.ArgumentParser(description="Linux kernel .config editor")
    parser.add_argument("options", nargs="+", help="e.g. CONFIG_KSU=y")
    args = parser.parse_args()

    changes = {}
    for opt in args.options:
        if "=" not in opt:
            parser.error(f"Invalid option: {opt}. Expected CONFIG_X=value")
        key, value = opt.split("=", 1)
        if not re.fullmatch(r"CONFIG_[A-Za-z0-9_]+", key):
            parser.error(f"Invalid config key: {key}")
        if value not in ("y", "m", "n") and not re.fullmatch(r'"[^"\n]*"|[0-9]+', value):
            parser.error(f"Invalid config value: {value}")
        changes[key] = value

    if not CONFIG_PATH.is_file():
        print(f"Error: {CONFIG_PATH} does not exist"); sys.exit(1)

    try:
        lines = CONFIG_PATH.read_text(encoding="utf-8", errors="replace").splitlines(keepends=True)
        updated, found = [], set()

        for line in lines:
            m = re.match(r"^(?:# )?(CONFIG_[A-Za-z0-9_]+)(?:=.*| is not set)\s*$", line.rstrip("\n"))
            if m and (key := m.group(1)) in changes:
                updated.append(f"{key}={changes[key]}\n"); found.add(key)
            else:
                updated.append(line)

        for key, value in changes.items():
            if key not in found:
                updated.append(f"{key}={value}\n")

        CONFIG_PATH.write_text("".join(updated), encoding="utf-8")

        for key, value in changes.items():
            print(f"  {key}={value}")
        print(f"\nUpdated {len(changes)} configuration option(s).")

    except OSError as e:
        print(f"Error: {e}"); sys.exit(1)

if __name__ == "__main__":
    main()