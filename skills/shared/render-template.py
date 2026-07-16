#!/usr/bin/env python3
"""Render a {PLACEHOLDER} template with LITERAL values.

Usage: render-template.py TEMPLATE_FILE [NAME=VALUE ...]

Why this exists (2026-07-16 incident): review skills used to fill
skills/shared/code-review-prompt.md with bash `${PROMPT//\\{DESCRIPTION\\}/$DESC}`.
On bash >= 5.2 the `patsub_replacement` shopt is ON by default: an unquoted `&`
in the replacement expands to the matched pattern and `\\&`/`\\` get special
handling, so a CONTEXT like `cd test-server && python3 -m unittest` rendered as
`cd test-server {DESCRIPTION}{DESCRIPTION} python3 -m unittest`. Values passed
here via argv are substituted with str-level replacement — literal on every
bash and python version.

Semantics:
  - every {NAME} whose NAME was supplied is replaced by its VALUE, verbatim;
  - single pass: placeholder-looking text INSIDE a value is never re-substituted;
  - {NAME}s not supplied stay as-is (tolerant to template evolution);
  - NAME must match [A-Za-z_][A-Za-z0-9_]*; VALUE may contain anything,
    including '=', newlines, '&', '\\', quotes and braces.

Exit codes:
  0 — success (rendered template on stdout)
  2 — usage error (no template arg, pair without '=', invalid NAME)
  3 — template unreadable
"""
from __future__ import annotations

import re
import sys

NAME_RE = re.compile(r"[A-Za-z_][A-Za-z0-9_]*\Z")
PLACEHOLDER_RE = re.compile(r"\{([A-Za-z_][A-Za-z0-9_]*)\}")


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print(f"usage: {argv[0]} TEMPLATE_FILE [NAME=VALUE ...]", file=sys.stderr)
        return 2

    values: dict[str, str] = {}
    for pair in argv[2:]:
        name, eq, value = pair.partition("=")
        if not eq or not NAME_RE.match(name):
            print(f"render-template: bad NAME=VALUE pair: {pair!r}", file=sys.stderr)
            return 2
        values[name] = value

    try:
        with open(argv[1], "r", encoding="utf-8", errors="surrogateescape") as fh:
            text = fh.read()
    except OSError as exc:
        print(f"render-template: cannot read template: {exc}", file=sys.stderr)
        return 3

    rendered = PLACEHOLDER_RE.sub(lambda m: values.get(m.group(1), m.group(0)), text)
    # bytes + surrogateescape: immune to a non-UTF-8 locale on the caller side.
    sys.stdout.buffer.write(rendered.encode("utf-8", errors="surrogateescape"))
    sys.stdout.buffer.flush()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
