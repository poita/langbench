import pytest

from gitrepo.delta import apply_delta
from gitrepo.errors import CorruptObjectError


def test_copy_and_insert():
    base = b"0123456789"
    # sizes: base 10, result 8 ; copy offset 2 size 4 ; insert "ab" ; copy offset 0 size 2
    delta = bytes([10, 8, 0x91, 2, 4, 2]) + b"ab" + bytes([0x91, 0, 2])
    assert apply_delta(base, delta) == b"2345ab01"


def test_copy_size_zero_means_64k():
    base = bytes(range(256)) * 256
    delta = bytes([0x80, 0x80, 0x04, 0x80, 0x80, 0x04])  # header only: sizes 65536/65536
    delta += bytes([0x80])  # copy offset 0, size 0 -> 0x10000
    assert apply_delta(base, delta) == base


@pytest.mark.parametrize("delta", [
    bytes([3, 3, 0x00]),                  # opcode 0
    bytes([3, 3, 0x91, 2, 5]),            # copy past the end
    bytes([3, 4, 0x91, 0, 3]),            # wrong result size
    bytes([4, 3, 0x91, 0, 3]),            # wrong base size
    bytes([3, 3, 5, 1]),                  # truncated insert
])
def test_damaged(delta):
    with pytest.raises(CorruptObjectError):
        apply_delta(b"abc", delta)
