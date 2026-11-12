"""Run the shared stdin-mode corpus (problems/toml/tests) when it is present."""

from pathlib import Path

import pytest

from tomlcodec import cli

CORPUS = Path(__file__).resolve().parents[2] / "problems" / "toml" / "tests"
CASES = sorted(CORPUS.glob("*.in")) if CORPUS.is_dir() else []


def normalize(text: str) -> str:
    return "\n".join(line.rstrip() for line in text.replace("\r\n", "\n").split("\n")).rstrip("\n")


@pytest.mark.skipif(not CASES, reason="corpus not available")
@pytest.mark.parametrize("case", CASES, ids=[c.stem for c in CASES])
def test_corpus_case(case):
    expected = case.with_suffix(".out").read_text(encoding="utf-8")
    actual = cli.run(case.read_bytes()).decode("utf-8")
    assert normalize(actual) == normalize(expected)
