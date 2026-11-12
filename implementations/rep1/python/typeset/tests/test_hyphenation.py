import pytest

from typeset.patterns import PatternLibrary


@pytest.fixture(scope="module")
def english(data_dir):
    return PatternLibrary(data_dir).get("english")


@pytest.mark.parametrize("word,expected", [
    ("winter", (3,)),
    ("typesetting", (7, 8)),
    ("national", (2, 4)),
    ("introduction", (2, 8)),
    ("algorithm", (2, 4)),  # exception
])
def test_spec_traces(english, word, expected):
    assert english.breaks(word) == expected


def test_pattern_parsing():
    from typeset.patterns import PatternSet
    ps = PatternSet()
    ps.add_pattern(".anti3")
    ps.add_pattern("c2h")
    assert ps.patterns[".anti"] == (0, 0, 0, 0, 0, 3)
    assert ps.patterns["ch"] == (0, 2, 0)
