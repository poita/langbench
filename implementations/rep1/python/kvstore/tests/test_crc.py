import pytest

from tessera import crc32


@pytest.mark.parametrize("data, expected", [
    (b"", 0x00000000),
    (b"a", 0xE8B7BE43),
    (b"123456789", 0xCBF43926),
    (b"TESSERA1", 0x2C9A9B66),
    (b"TESSWAL1", 0x7D446716),
    (bytes(20), 0x0FD59B8D),
    (bytes(1024), 0xEFB5AF2E),
])
def test_spec_vectors(data, expected):
    assert crc32(data) == expected


def test_incremental():
    assert crc32(b"456789", crc32(b"123")) == crc32(b"123456789")
