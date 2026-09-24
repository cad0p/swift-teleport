#!/usr/bin/env python3
"""Package boundary + license gate for swift-teleport.

Two independent checks, both fail-closed:

  1. LICENSE — no tracked file may carry the AGPL SPDX marker. This package is
     MIT and ships no AGPL text; the Teleport-derived files that need the AGPL
     carve-out stay host-side in cad0p/vvterm (see THIRD_PARTY_NOTICES.md and
     docs/PROVENANCE.md).

  2. BOUNDARY — no file under `Sources/` (every target: `TeleportCore`,
     `TeleportAuth`, `TeleportTesting`) may reference a host symbol. The
     package must not depend on the host app's error types, logging, defaults,
     auth model, keyring singleton, bundle id, or host-only observation
     protocol; those are injected through the D6 seam protocols.

Run from the package root:

    python3 -B scripts/ci/check-package-boundaries.py
    python3 -B scripts/ci/check-package-boundaries.py --selftest

(`-B` keeps the run from writing `__pycache__/`; the repo also gitignores it.)

Comment stripping is fail-closed: only full-line comments (`^\\s*//`,
`^\\s*\\*`) and block comments are removed. A trailing `//` after code is NOT
treated as a comment, so a `//` inside a string literal (e.g. an `https://`
URL) cannot hide a forbidden token on the same line.
"""

from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
SELF = "scripts/ci/check-package-boundaries.py"

AGPL_MARKER = "SPDX-License-Identifier: AGPL-3.0-or-later"

SOURCE_ROOT = "Sources"

# Host symbols/strings forbidden inside the package sources. `\b` keeps the
# package's own `TeleportSessionMutex` protocol allowed. `TeleportKeyRingStoring`
# is the host-only `@MainActor` observation protocol: the package keyring
# conforms to the plain `TeleportCredentialStore` seam, and the host restores
# the observation conformance by extension in Phase 2.
FORBIDDEN = re.compile(
    r"SSHError"
    r"|KeychainError"
    r"|Logger\.forCategory"
    r"|UserDefaults\.standard"
    r"|AuthMethod"
    r"|TeleportKeyRing\.shared"
    r"|app\.vivy\.vvterm"
    r"|\bSessionMutex\b"
    r"|TeleportKeyRingStoring"
)

BLOCK_COMMENT = re.compile(r"/\*.*?\*/", re.DOTALL)
# Full-line `//` comments only (anchored at the line start after optional
# horizontal whitespace) — a trailing `//` after code may live inside a
# string literal and must not hide anything.
LINE_COMMENT = re.compile(r"^[ \t]*//[^\n]*", re.MULTILINE)
# `*` continuation lines (e.g. JSDoc style) outside a block comment.
DOC_LINE = re.compile(r"^[ \t]*\*[^\n]*", re.MULTILINE)


def strip_comments(source: str) -> str:
    without_blocks = BLOCK_COMMENT.sub("", source)
    without_line_comments = LINE_COMMENT.sub("", without_blocks)
    return DOC_LINE.sub("", without_line_comments)


def tracked_files() -> list[str]:
    result = subprocess.run(
        ["git", "ls-files"],
        cwd=REPO_ROOT,
        check=True,
        capture_output=True,
        text=True,
    )
    return [line for line in result.stdout.splitlines() if line]


def read_text(relative: str) -> str | None:
    path = REPO_ROOT / relative
    try:
        return path.read_text(encoding="utf-8")
    except (UnicodeDecodeError, OSError):
        return None  # binary or unreadable — cannot carry the marker


def check_license() -> list[str]:
    hits: list[str] = []
    for relative in tracked_files():
        if relative == SELF:
            continue
        text = read_text(relative)
        if text is not None and AGPL_MARKER in text:
            hits.append(f"{relative}: carries the AGPL SPDX marker")
    return hits


def check_boundary() -> list[str]:
    hits: list[str] = []
    checked = 0
    for relative in tracked_files():
        if not relative.startswith(f"{SOURCE_ROOT}/") or not relative.endswith(".swift"):
            continue
        text = read_text(relative)
        if text is None:
            continue
        checked += 1
        stripped = strip_comments(text)
        for lineno, line in enumerate(stripped.splitlines(), start=1):
            if FORBIDDEN.search(line):
                hits.append(f"{relative}:{lineno}: {line.strip()}")
    if checked == 0:
        hits.append(f"{SOURCE_ROOT}: no Swift sources found")
    return hits


def run_selftest() -> int:
    """Prove both checks catch planted tokens and the stripper is safe."""
    failures: list[str] = []

    # BOUNDARY cases: (source, should_match).
    boundary_cases: list[tuple[str, bool]] = [
        ('let error = SSHError.connectionFailed("boom")', True),
        # A `//` inside a string literal must not hide the token after it.
        ('let url = "https://example.com" // SSHError', True),
        ("let mutex = SessionMutex()", True),
        ("// SSHError in a full-line comment", False),
        ("/// Logger.forCategory in a doc comment", False),
        ("/* SSHError in a block comment */", False),
        ("/**\n * KeychainError in a doc block\n */", False),
        # The package protocol is not the host `SessionMutex`.
        ("let mutex: any TeleportSessionMutex = factory()", False),
        ("let store = TeleportKeyRing.shared", True),
        ("let defaults = UserDefaults.standard", True),
        ("extension TeleportKeyRing: TeleportKeyRingStoring {}", True),
        ("let seam: any TeleportCredentialStore = ring", False),
    ]
    for source, should_match in boundary_cases:
        matched = bool(FORBIDDEN.search(strip_comments(source)))
        if matched != should_match:
            failures.append(
                f"  boundary {source!r}: expected match={should_match}, got match={matched}"
            )

    # LICENSE cases.
    if AGPL_MARKER not in f"// {AGPL_MARKER}":
        failures.append("  license: marker detection is broken")

    if failures:
        print("check-package-boundaries selftest FAILED:")
        print("\n".join(failures))
        return 1
    print(
        f"check-package-boundaries selftest OK — "
        f"{len(boundary_cases)} boundary cases + 1 license case."
    )
    return 0


def main(argv: list[str]) -> int:
    if "--selftest" in argv:
        return run_selftest()

    failures: list[str] = []
    failures.extend(check_license())
    failures.extend(check_boundary())

    if failures:
        print("check-package-boundaries FAILED:")
        for failure in failures:
            print(f"  {failure}")
        return 1

    sources = len(
        [
            f
            for f in tracked_files()
            if f.startswith(f"{SOURCE_ROOT}/") and f.endswith(".swift")
        ]
    )
    print(
        f"check-package-boundaries OK — {len(tracked_files())} tracked files carry no "
        f"AGPL marker; {sources} package source(s) carry no host symbol "
        f"({FORBIDDEN.pattern})."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
