import pytest

from depresolve import Version


def test_parse_and_str_roundtrip():
    assert Version.parse("1.20.300") == Version(1, 20, 300)
    assert str(Version(0, 0, 0)) == "0.0.0"


def test_numeric_comparison():
    assert Version.parse("1.10.0") > Version.parse("1.9.0")
    assert Version(2, 0, 0) > Version(1, 999999, 999999)


def test_key_order_matches_version_order():
    vs = [Version(1, 0, 0), Version(0, 1000000, 1000000), Version(1, 0, 1), Version(0, 0, 1)]
    assert sorted(vs) == sorted(vs, key=lambda v: v.key)


@pytest.mark.parametrize("bad", ["1.2", "1.2.3.4", "a.b.c", "1..2", ""])
def test_parse_rejects_malformed(bad):
    with pytest.raises(ValueError):
        Version.parse(bad)
