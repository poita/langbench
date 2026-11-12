import pytest

from depresolve import Version, VersionRange


def accepts(rng: str, ver: str) -> bool:
    return Version.parse(ver) in VersionRange.parse(rng)


@pytest.mark.parametrize(
    "rng, ver, expected",
    [
        ("*", "0.0.0", True),
        ("*", "1000000.1000000.1000000", True),
        ("1.2.3", "1.2.3", True),
        ("1.2.3", "1.2.4", False),
        ("^1.2.3", "1.2.3", True),
        ("^1.2.3", "1.9.0", True),
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
        ("<1.0.0", "0.9.9", True),
        ("<1.0.0", "1.0.0", False),
        ("<=1.0.0", "1.0.0", True),
        (">1.0.0", "1.0.0", False),
        (">1.0.0", "1.0.1", True),
        (">=1.0.0", "1.0.0", True),
        (">=1.0.0 <2.0.0", "1.5.0", True),
        (">=1.0.0 <2.0.0", "2.0.0", False),
        (">1.0.0 <=1.0.1", "1.0.1", True),
        ("<=1000000.1000000.1000000", "1000000.1000000.1000000", True),
        ("^1000000.0.0", "1000000.5.5", True),
    ],
)
def test_range_semantics(rng, ver, expected):
    assert accepts(rng, ver) is expected


def test_contradictory_range_is_empty():
    r = VersionRange.parse(">=2.0.0 <1.0.0")
    assert r.is_empty
    assert not r.contains(Version(1, 5, 0))
