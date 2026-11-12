import pytest

from protowire import ProtowireError
from protowire.wire import put_varint, read_tag, read_varint, skip_group, varint_size


def varint(v):
    out = bytearray()
    put_varint(out, v)
    return bytes(out)


@pytest.mark.parametrize(
    "value,hexed",
    [(0, "00"), (1, "01"), (300, "ac02"), (2**64 - 1, "ff" * 9 + "01")],
)
def test_minimal_varint(value, hexed):
    assert varint(value).hex() == hexed
    assert varint_size(value) == len(hexed) // 2
    assert read_varint(bytes.fromhex(hexed), 0, len(hexed) // 2) == (value, len(hexed) // 2)


def test_non_minimal_and_overflow_varints_accepted():
    assert read_varint(b"\x81\x00", 0, 2) == (1, 2)
    assert read_varint(bytes.fromhex("ff" * 9 + "7f"), 0, 10)[0] == 2**64 - 1
    assert read_varint(bytes.fromhex("80" * 9 + "02"), 0, 10)[0] == 0


def test_varint_errors():
    with pytest.raises(ProtowireError):
        read_varint(b"\xff", 0, 1)  # truncated
    with pytest.raises(ProtowireError):
        read_varint(b"\x80" * 10 + b"\x00", 0, 11)  # 11 bytes
    with pytest.raises(ProtowireError):
        read_varint(b"", 0, 0)


def test_tag_rules():
    assert read_tag(b"\x08", 0, 1) == (1, 0, 1)
    for bad in (b"\x00", b"\x0e", b"\x0f", b"\x80\x80\x80\x80\x80\x00", b"\xff\xff\xff\xff\x1f"):
        with pytest.raises(ProtowireError):
            read_tag(bad, 0, len(bad))


def test_skip_nested_group():
    data = bytes.fromhex("0b1b08011c0c")
    # outer group field 1 containing group field 3, closed by 0c
    assert skip_group(data, 1, len(data), 1) == len(data)


def test_skip_group_mismatch():
    with pytest.raises(ProtowireError):
        skip_group(bytes.fromhex("14"), 0, 1, 3)
