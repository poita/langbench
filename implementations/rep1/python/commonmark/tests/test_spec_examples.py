"""The CommonMark 0.31.2 spec examples that fall inside the supported subset."""

import json
from pathlib import Path

import pytest

from cmarkpy import convert

EXAMPLES = json.loads((Path(__file__).parent / "data" / "spec_examples.json").read_text(encoding="utf-8"))


@pytest.mark.parametrize("ex", EXAMPLES, ids=[f"{e['n']}-{e['sec']}" for e in EXAMPLES])
def test_spec_example(ex):
    assert convert(ex["md"]) == ex["html"]
