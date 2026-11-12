import pytest

from depresolve import Version, parse_range


def accepts(rng: str, ver: str) -> bool:
    return Version.parse(ver) in parse_range(rng)


def test_numeric_comparison():
    assert Version.parse("1.10.0") > Version.parse("1.9.0")
    assert str(Version(1, 2, 3)) == "1.2.3"


@pytest.mark.parametrize(
    "rng, ver, ok",
    [
        ("*", "0.0.0", True),
        ("1.2.3", "1.2.3", True),
        ("1.2.3", "1.2.4", False),
        ("^1.2.3", "1.9.9", True),
        ("^1.2.3", "2.0.0", False),
        ("^1.2.3", "1.2.2", False),
        ("^0.2.3", "0.2.9", True),
        ("^0.2.3", "0.3.0", False),
        ("^0.0.3", "0.0.3", True),
        ("^0.0.3", "0.0.4", False),
        ("~1.2.3", "1.2.9", True),
        ("~1.2.3", "1.3.0", False),
        ("~0.0.3", "0.0.9", True),
        ("~0.0.3", "0.1.0", False),
        (">1.0.0", "1.0.0", False),
        (">1.0.0", "1.0.1", True),
        (">=1.0.0", "1.0.0", True),
        ("<1.0.0", "1.0.0", False),
        ("<=1.0.0", "1.0.0", True),
        (">=1.0.0 <2.0.0", "1.5.0", True),
        (">=1.0.0 <2.0.0", "2.0.0", False),
        (">=2.0.0 <1.0.0", "1.5.0", False),
        (">1.0.0 <=1.0.1", "1.0.1", True),
    ],
)
def test_range_semantics(rng, ver, ok):
    assert accepts(rng, ver) is ok


def test_empty_range():
    assert parse_range(">=2.0.0 <1.0.0").is_empty()
    assert not parse_range("*").is_empty()
