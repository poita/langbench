import hashlib
import os

import pytest

from gitrepo.sha1 import Sha1, sha1_hex


def test_known_vectors():
    assert sha1_hex(b"") == "da39a3ee5e6b4b0d3255bfef95601890afd80709"
    assert sha1_hex(b"abc") == "a9993e364706816aba3e25717850c26c9cd0d89d"
    assert sha1_hex(b"blob 9\0one file\n") == "b7814cae2e925fe74c6cd5816462fff515ccb256"


@pytest.mark.parametrize("n", [0, 1, 55, 56, 57, 63, 64, 65, 119, 120, 1000, 5000])
def test_matches_hashlib(n):
    data = os.urandom(n)
    assert sha1_hex(data) == hashlib.sha1(data).hexdigest()


def test_incremental():
    data = os.urandom(777)
    h = Sha1()
    for i in range(0, len(data), 37):
        h.update(data[i:i + 37])
    assert h.hexdigest() == hashlib.sha1(data).hexdigest()
    assert h.digest() == bytes.fromhex(h.hexdigest())
