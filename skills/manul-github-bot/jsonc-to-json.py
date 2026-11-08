#!/usr/bin/env python3
"""Convert JSONC to strict JSON without modifying its source file."""
from __future__ import annotations
import json
import sys
from pathlib import Path

def strip_comments(source: str) -> str:
    output: list[str] = []
    index = 0
    in_string = escaped = line_comment = block_comment = False
    while index < len(source):
        char = source[index]
        nxt = source[index + 1] if index + 1 < len(source) else ""
        if line_comment:
            if char in "\r\n":
                line_comment = False
                output.append(char)
            else:
                output.append(" ")
            index += 1
            continue
        if block_comment:
            if char == "*" and nxt == "/":
                output.extend((" ", " "))
                index += 2
                block_comment = False
            else:
                output.append("\n" if char == "\n" else " ")
                index += 1
            continue
        if in_string:
            output.append(char)
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == '"':
                in_string = False
            index += 1
            continue
        if char == '"':
            in_string = True
            output.append(char)
            index += 1
        elif char == "/" and nxt == "/":
            output.extend((" ", " "))
            index += 2
            line_comment = True
        elif char == "/" and nxt == "*":
            output.extend((" ", " "))
            index += 2
            block_comment = True
        else:
            output.append(char)
            index += 1
    if in_string or block_comment:
        raise ValueError("unterminated JSONC string or block comment")
    return "".join(output)

def strip_trailing_commas(source: str) -> str:
    output: list[str] = []
    index = 0
    in_string = escaped = False
    while index < len(source):
        char = source[index]
        if in_string:
            output.append(char)
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == '"':
                in_string = False
            index += 1
            continue
        if char == '"':
            in_string = True
            output.append(char)
            index += 1
            continue
        if char == ",":
            lookahead = index + 1
            while lookahead < len(source) and source[lookahead].isspace():
                lookahead += 1
            if lookahead < len(source) and source[lookahead] in "}]":
                index += 1
                continue
        output.append(char)
        index += 1
    return "".join(output)

def main() -> int:
    if len(sys.argv) > 2:
        print("usage: jsonc-to-json.py [path]", file=sys.stderr)
        return 2
    try:
        source = Path(sys.argv[1]).read_text(encoding="utf-8") if len(sys.argv) == 2 else sys.stdin.read()
        parsed = json.loads(strip_trailing_commas(strip_comments(source)))
        json.dump(parsed, sys.stdout, ensure_ascii=False, separators=(",", ":"))
        sys.stdout.write("\n")
        return 0
    except (OSError, UnicodeError, ValueError, json.JSONDecodeError) as error:
        print(f"jsonc-to-json: {error}", file=sys.stderr)
        return 1

if __name__ == "__main__":
    raise SystemExit(main())
