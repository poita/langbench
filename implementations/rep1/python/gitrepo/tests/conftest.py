"""Shared fixtures: a tiny git repository written by hand (loose objects and a pack).

The tests may use ``zlib`` and ``hashlib`` to *produce* fixtures and to
cross-check the library; the library itself never imports them.
"""

import hashlib
import os
import struct
import zlib

import pytest


def oid_of(kind: bytes, payload: bytes) -> str:
    return hashlib.sha1(b"%s %d\0" % (kind, len(payload)) + payload).hexdigest()


class RepoBuilder:
    def __init__(self, root):
        self.root = root
        self.git = root / "repo"
        (self.git / "objects" / "pack").mkdir(parents=True)
        (self.git / "refs" / "heads").mkdir(parents=True)
        (self.git / "refs" / "tags").mkdir(parents=True)

    def loose(self, kind: bytes, payload: bytes, compress=zlib.compress) -> str:
        oid = oid_of(kind, payload)
        path = self.git / "objects" / oid[:2]
        path.mkdir(exist_ok=True)
        (path / oid[2:]).write_bytes(compress(b"%s %d\0" % (kind, len(payload)) + payload))
        return oid

    def blob(self, data: bytes) -> str:
        return self.loose(b"blob", data)

    def tree(self, entries) -> str:
        body = b"".join(b"%s %s\0%s" % (mode, name, bytes.fromhex(oid))
                        for mode, name, oid in entries)
        return self.loose(b"tree", body)

    def commit(self, tree, parents=(), when=1000, name=b"Ada", msg=b"msg\n") -> str:
        lines = [b"tree " + tree.encode()]
        lines += [b"parent " + p.encode() for p in parents]
        lines.append(b"author %s <a@b> %d +0000" % (name, when))
        lines.append(b"committer %s <a@b> %d +0000" % (name, when))
        return self.loose(b"commit", b"\n".join(lines) + b"\n\n" + msg)

    def tag(self, target, kind=b"commit", name=b"v1") -> str:
        body = b"object %s\ntype %s\ntag %s\ntagger T <t@t> 5 +0000\n\nrel\n" % (
            target.encode(), kind, name)
        return self.loose(b"tag", body)

    def ref(self, name: str, content: str) -> None:
        p = self.git / name
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(content + "\n")

    def commands(self, *lines: str) -> None:
        (self.root / "commands.txt").write_text("\n".join(lines))

    def write_pack(self, name, objects):
        """objects: list of (kind, payload) | ('ofs', base_index, delta) | ('ref', id, delta)."""
        data = b"PACK" + struct.pack(">II", 2, len(objects))
        offsets, ids = [], []
        for obj in objects:
            offsets.append(len(data))
            tag = obj[0]
            if tag in (b"commit", b"tree", b"blob", b"tag"):
                tcode = {b"commit": 1, b"tree": 2, b"blob": 3, b"tag": 4}[tag]
                payload = obj[1]
                data += self._header(tcode, len(payload)) + zlib.compress(payload)
            elif tag == "ofs":
                delta = obj[2]
                back = offsets[-1] - offsets[obj[1]]
                enc = [back & 0x7F]
                back >>= 7
                while back:
                    back -= 1
                    enc.append(0x80 | (back & 0x7F))
                    back >>= 7
                data += self._header(6, len(delta)) + bytes(reversed(enc)) + zlib.compress(delta)
            else:
                delta = obj[2]
                data += self._header(7, len(delta)) + bytes.fromhex(obj[1]) + zlib.compress(delta)
        data += hashlib.sha1(data).digest()
        (self.git / "objects" / "pack" / f"{name}.pack").write_bytes(data)
        return offsets

    @staticmethod
    def _header(tcode, size):
        b = (tcode << 4) | (size & 15)
        size >>= 4
        out = bytearray()
        while size:
            out.append(b | 0x80)
            b = size & 0x7F
            size >>= 7
        out.append(b)
        return bytes(out)

    def write_index(self, name, entries):
        """entries: list of (hex id, offset)."""
        entries = sorted(entries)
        fan = [0] * 256
        for oid, _ in entries:
            fan[int(oid[:2], 16)] += 1
        for i in range(1, 256):
            fan[i] += fan[i - 1]
        data = b"\xfftOc" + struct.pack(">I", 2) + struct.pack(">256I", *fan)
        data += b"".join(bytes.fromhex(o) for o, _ in entries)
        data += b"\0\0\0\0" * len(entries)
        data += b"".join(struct.pack(">I", off) for _, off in entries)
        data += b"\0" * 40
        (self.git / "objects" / "pack" / f"{name}.idx").write_bytes(data)


@pytest.fixture
def builder(tmp_path):
    return RepoBuilder(tmp_path)


def make_delta(base: bytes, result: bytes) -> bytes:
    """A trivial delta: copy the common prefix of base, insert the rest."""
    def size(n):
        out = bytearray()
        while True:
            b = n & 0x7F
            n >>= 7
            if n:
                out.append(b | 0x80)
            else:
                out.append(b)
                return bytes(out)
    k = 0
    while k < min(len(base), len(result), 0xFFFF) and base[k] == result[k]:
        k += 1
    out = size(len(base)) + size(len(result))
    if k:
        out += bytes([0x80 | 0x10 | 0x20]) + struct.pack("<H", k)[0:2]
    rest = result[k:]
    for i in range(0, len(rest), 127):
        chunk = rest[i:i + 127]
        out += bytes([len(chunk)]) + chunk
    return out
