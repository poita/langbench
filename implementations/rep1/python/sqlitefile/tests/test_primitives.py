import pytest

from dbbuilder import record, varint
from sqlitefile.errors import FormatError
from sqlitefile.record import decode_record
from sqlitefile.varint import read_varint


@pytest.mark.parametrize(
    "n", [0, 1, 127, 128, 16383, 16384, 2**32, 2**56 - 1, 2**56, 2**63 - 1, -1, -(2**63)]
)
def test_varint_roundtrip(n):
    enc = varint(n)
    assert read_varint(enc + b"xx", 0) == (n, len(enc))


def test_negative_rowid_is_nine_bytes():
    assert len(varint(-5)) == 9
    assert read_varint(varint(-5), 0)[0] == -5


def test_varint_truncated():
    with pytest.raises(FormatError):
        read_varint(b"\x80", 0)


def test_record_all_serial_types():
    values = [None, 0, 1, 100, -200, 70000, 2**31, 2**40, -(2**62), 1.5, "héllo", b"\xff\x00", ""]
    assert decode_record(record(values)) == values


def test_record_short_is_padded_with_null():
    assert decode_record(record([1, 2]), ncols=4) == [1, 2, None, None]


def test_record_wanted_columns_only():
    assert decode_record(record(["a", "bb", "ccc"]), wanted={1}) == [None, "bb", None]


def test_record_invalid_serial_type():
    with pytest.raises(FormatError):
        decode_record(b"\x02\x0a")
