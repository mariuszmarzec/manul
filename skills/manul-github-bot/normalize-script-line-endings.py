#!/usr/bin/env python3
"""Normalize CRLF endings in Manul's top-level executable source scripts."""

from __future__ import annotations

import sys
from pathlib import Path

SCRIPT_SUFFIXES = {".sh", ".zsh", ".py"}


def main() -> int:
    if len(sys.argv) < 2:
        print(f"Usage: {Path(sys.argv[0]).name} <canonical-directory> [...]", file=sys.stderr)
        return 2

    changed: list[Path] = []
    for raw_root in sys.argv[1:]:
        root = Path(raw_root)
        if not root.is_dir():
            print(f"ERROR: script directory does not exist: {root}", file=sys.stderr)
            return 1

        for path in root.iterdir():
            # Only modify regular files owned by the canonical checkout. Do
            # not follow symlinks that could point outside the Manul source.
            if path.is_symlink() or path.suffix not in SCRIPT_SUFFIXES or not path.is_file():
                continue

            try:
                original = path.read_bytes()
                normalized = original.replace(b"\r\n", b"\n")
                if normalized != original:
                    path.write_bytes(normalized)
                    changed.append(path)
            except OSError as exc:
                print(f"ERROR: cannot normalize {path}: {exc}", file=sys.stderr)
                return 1

    if changed:
        print(
            f"Normalized CRLF line endings in {len(changed)} Manul script(s): "
            + ", ".join(path.name for path in changed),
            file=sys.stderr,
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
