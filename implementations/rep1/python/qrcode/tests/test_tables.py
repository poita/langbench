import pytest

from qrcode.tables import ErrorCorrection, data_codewords, raw_modules, symbol_size, total_codewords


@pytest.mark.parametrize(
    "version, ecl, expected",
    [
        (1, "L", 19), (1, "M", 16), (1, "Q", 13), (1, "H", 9),
        (40, "L", 2956), (40, "H", 1276),
    ],
)
def test_data_codewords(version, ecl, expected):
    assert data_codewords(version, ErrorCorrection[ecl]) == expected


def test_raw_modules_known_values():
    assert raw_modules(1) == 208
    assert raw_modules(7) == 1568
    assert raw_modules(40) == 29648


def test_total_codewords_and_size():
    assert total_codewords(1) == 26
    assert symbol_size(1) == 21
    assert symbol_size(40) == 177


def test_version_range_checked():
    with pytest.raises(ValueError):
        raw_modules(0)
    with pytest.raises(ValueError):
        raw_modules(41)


def test_parse_level():
    assert ErrorCorrection.parse("q") is ErrorCorrection.Q
    assert ErrorCorrection.parse(ErrorCorrection.H) is ErrorCorrection.H
    with pytest.raises(ValueError):
        ErrorCorrection.parse("X")
