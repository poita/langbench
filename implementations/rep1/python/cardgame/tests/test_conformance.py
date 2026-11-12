"""Run the shipped problem test-suite, when it is available.

Looks for ``problems/cardgame/tests`` next to the project (or at the path in
``CARDGAME_PROBLEM_DIR``) and compares every ``.in`` file's output with its
``.out`` file.  Skipped when the directory is absent.
"""

from __future__ import annotations

import os
from pathlib import Path

import pytest

from cardgame import run_match

ROOT = Path(__file__).resolve().parent.parent
PROBLEM = Path(os.environ.get("CARDGAME_PROBLEM_DIR",
                              ROOT.parent / "problems" / "cardgame"))
CASES = sorted((PROBLEM / "tests").glob("*.in")) if PROBLEM.is_dir() else []


def _normal(text: str) -> list[str]:
    return [ln.rstrip() for ln in text.rstrip("\n").split("\n")]


@pytest.mark.skipif(not CASES, reason="problem test-suite not available")
@pytest.mark.parametrize("case", CASES, ids=[c.stem for c in CASES])
def test_case(case, monkeypatch):
    monkeypatch.chdir(PROBLEM)
    got = run_match(case.read_text(encoding="utf-8"))
    want = case.with_suffix(".out").read_text(encoding="utf-8")
    assert _normal(got) == _normal(want)
