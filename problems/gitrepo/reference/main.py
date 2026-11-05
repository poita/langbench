#!/usr/bin/env python3
"""Reference implementation of the gitrepo problem.

Reads a git object database directly: SHA-1, DEFLATE and the packfile format
are all implemented here, with no zlib, no hashlib and no git.

Usage: main.py <input dir> <output dir>
"""
import os
import struct
import sys

# --------------------------------------------------------------------- SHA-1

_K = (0x5A827999, 0x6ED9EBA1, 0x8F1BBCDC, 0xCA62C1D6)


def sha1_hex(data):
    """SHA-1 (FIPS 180-4) of `data`, as 40 lowercase hex digits."""
    h0, h1, h2, h3, h4 = (0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476,
                          0xC3D2E1F0)
    bitlen = len(data) * 8
    data = data + b"\x80" + b"\x00" * ((55 - len(data)) % 64) + \
        bitlen.to_bytes(8, "big")
    mask = 0xFFFFFFFF
    for off in range(0, len(data), 64):
        w = list(struct.unpack(">16I", data[off:off + 64]))
        for i in range(16, 80):
            x = w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16]
            w.append(((x << 1) | (x >> 31)) & mask)
        a, b, c, d, e = h0, h1, h2, h3, h4
        for i in range(80):
            if i < 20:
                f = d ^ (b & (c ^ d))
                k = _K[0]
            elif i < 40:
                f = b ^ c ^ d
                k = _K[1]
            elif i < 60:
                f = (b & c) | (d & (b | c))
                k = _K[2]
            else:
                f = b ^ c ^ d
                k = _K[3]
            t = (((a << 5) | (a >> 27)) + f + e + k + w[i]) & mask
            e = d
            d = c
            c = ((b << 30) | (b >> 2)) & mask
            b = a
            a = t
        h0 = (h0 + a) & mask
        h1 = (h1 + b) & mask
        h2 = (h2 + c) & mask
        h3 = (h3 + d) & mask
        h4 = (h4 + e) & mask
    return "%08x%08x%08x%08x%08x" % (h0, h1, h2, h3, h4)


# ------------------------------------------------------------------- DEFLATE

class GitError(Exception):
    """Any condition that makes a command's answer `error`."""


LBASE = (3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51,
         59, 67, 83, 99, 115, 131, 163, 195, 227, 258)
LEXT = (0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4,
        5, 5, 5, 5, 0)
DBASE = (1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385,
         513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385,
         24577)
DEXT = (0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10,
        10, 11, 11, 12, 12, 13, 13)
CLEN_ORDER = (16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15)


def build_table(lengths):
    """Builds a flat decode table for a canonical Huffman code.

    The table is indexed by the next `maxlen` input bits read LSB-first, so a
    code appears bit-reversed and is replicated at every index whose low bits
    match it. Entries hold (codelen << 16) | symbol, or -1 where no code
    matches. Filling by extended slice assignment keeps table construction
    cheap enough to run once per compressed object.
    """
    count = [0] * 16
    for l in lengths:
        count[l] += 1
    count[0] = 0
    maxlen = 0
    for l in range(15, 0, -1):
        if count[l]:
            maxlen = l
            break
    if maxlen == 0:
        return None, 0
    left = 1
    for l in range(1, 16):
        left = (left << 1) - count[l]
        if left < 0:
            raise GitError("over-subscribed huffman code")
    next_code = [0] * 17
    code = 0
    for l in range(1, 16):
        code = (code + count[l - 1]) << 1
        next_code[l] = code
    size = 1 << maxlen
    table = [-1] * size
    for sym, l in enumerate(lengths):
        if l == 0:
            continue
        c = next_code[l]
        next_code[l] += 1
        r = 0
        for _ in range(l):
            r = (r << 1) | (c & 1)
            c >>= 1
        step = 1 << l
        table[r::step] = [(l << 16) | sym] * ((size - r + step - 1) // step)
    return table, maxlen


def _fixed_tables():
    lit = [8] * 144 + [9] * 112 + [7] * 24 + [8] * 8
    return build_table(lit), build_table([5] * 32)


FIXED_LIT, FIXED_DIST = _fixed_tables()


def inflate_raw(data, pos):
    """Decompresses the raw DEFLATE stream in `data` starting at `pos`."""
    n = len(data)
    out = bytearray()
    bitbuf = 0
    bitcnt = 0
    while True:
        while bitcnt < 3:
            bitbuf |= (data[pos] if pos < n else 0) << bitcnt
            pos += 1
            bitcnt += 8
        final = bitbuf & 1
        btype = (bitbuf >> 1) & 3
        bitbuf >>= 3
        bitcnt -= 3
        if btype == 0:
            drop = bitcnt & 7
            bitbuf >>= drop
            bitcnt -= drop
            pos -= bitcnt >> 3
            bitbuf = 0
            bitcnt = 0
            if pos + 4 > n:
                raise GitError("truncated stored block")
            length = data[pos] | (data[pos + 1] << 8)
            nlen = data[pos + 2] | (data[pos + 3] << 8)
            if length ^ 0xFFFF != nlen:
                raise GitError("bad stored block length")
            pos += 4
            if pos + length > n:
                raise GitError("truncated stored block")
            out += data[pos:pos + length]
            pos += length
        elif btype == 3:
            raise GitError("reserved block type")
        else:
            if btype == 1:
                (lt, lmax), (dt, dmax) = FIXED_LIT, FIXED_DIST
            else:
                while bitcnt < 14:
                    bitbuf |= (data[pos] if pos < n else 0) << bitcnt
                    pos += 1
                    bitcnt += 8
                hlit = (bitbuf & 31) + 257
                hdist = ((bitbuf >> 5) & 31) + 1
                hclen = ((bitbuf >> 10) & 15) + 4
                bitbuf >>= 14
                bitcnt -= 14
                clens = [0] * 19
                for i in range(hclen):
                    while bitcnt < 3:
                        bitbuf |= (data[pos] if pos < n else 0) << bitcnt
                        pos += 1
                        bitcnt += 8
                    clens[CLEN_ORDER[i]] = bitbuf & 7
                    bitbuf >>= 3
                    bitcnt -= 3
                ct, cmax = build_table(clens)
                if ct is None:
                    raise GitError("empty code-length code")
                cmask = (1 << cmax) - 1
                lengths = []
                total = hlit + hdist
                while len(lengths) < total:
                    while bitcnt < cmax:
                        bitbuf |= (data[pos] if pos < n else 0) << bitcnt
                        pos += 1
                        bitcnt += 8
                    ent = ct[bitbuf & cmask]
                    if ent < 0:
                        raise GitError("invalid code-length code")
                    bitbuf >>= ent >> 16
                    bitcnt -= ent >> 16
                    sym = ent & 0xFFFF
                    if sym < 16:
                        lengths.append(sym)
                        continue
                    if sym == 16:
                        extra, base = 2, 3
                        if not lengths:
                            raise GitError("repeat with no previous length")
                        value = lengths[-1]
                    elif sym == 17:
                        extra, base, value = 3, 3, 0
                    else:
                        extra, base, value = 7, 11, 0
                    while bitcnt < extra:
                        bitbuf |= (data[pos] if pos < n else 0) << bitcnt
                        pos += 1
                        bitcnt += 8
                    rep = base + (bitbuf & ((1 << extra) - 1))
                    bitbuf >>= extra
                    bitcnt -= extra
                    lengths.extend([value] * rep)
                if len(lengths) != total:
                    raise GitError("code length overflow")
                lt, lmax = build_table(lengths[:hlit])
                dt, dmax = build_table(lengths[hlit:])
                if lt is None:
                    raise GitError("empty literal code")
            lmask = (1 << lmax) - 1
            dmask = (1 << dmax) - 1 if dt is not None else 0
            while True:
                while bitcnt < lmax:
                    bitbuf |= (data[pos] if pos < n else 0) << bitcnt
                    pos += 1
                    bitcnt += 8
                ent = lt[bitbuf & lmask]
                if ent < 0:
                    raise GitError("invalid literal code")
                bitbuf >>= ent >> 16
                bitcnt -= ent >> 16
                sym = ent & 0xFFFF
                if sym < 256:
                    out.append(sym)
                    continue
                if sym == 256:
                    break
                sym -= 257
                if sym >= 29:
                    raise GitError("invalid length code")
                extra = LEXT[sym]
                while bitcnt < extra:
                    bitbuf |= (data[pos] if pos < n else 0) << bitcnt
                    pos += 1
                    bitcnt += 8
                length = LBASE[sym] + (bitbuf & ((1 << extra) - 1))
                bitbuf >>= extra
                bitcnt -= extra
                if dt is None:
                    raise GitError("no distance code")
                while bitcnt < dmax:
                    bitbuf |= (data[pos] if pos < n else 0) << bitcnt
                    pos += 1
                    bitcnt += 8
                ent = dt[bitbuf & dmask]
                if ent < 0:
                    raise GitError("invalid distance code")
                bitbuf >>= ent >> 16
                bitcnt -= ent >> 16
                dsym = ent & 0xFFFF
                if dsym >= 30:
                    raise GitError("invalid distance code")
                extra = DEXT[dsym]
                while bitcnt < extra:
                    bitbuf |= (data[pos] if pos < n else 0) << bitcnt
                    pos += 1
                    bitcnt += 8
                dist = DBASE[dsym] + (bitbuf & ((1 << extra) - 1))
                bitbuf >>= extra
                bitcnt -= extra
                cur = len(out)
                if dist > cur:
                    raise GitError("distance too far back")
                if dist >= length:
                    out += out[cur - dist:cur - dist + length]
                else:
                    seg = bytes(out[cur - dist:])
                    out += (seg * (length // dist + 1))[:length]
        if final:
            return bytes(out)


def inflate_zlib(data, pos):
    """Decompresses the zlib (RFC 1950) stream in `data` starting at `pos`."""
    if pos + 2 > len(data):
        raise GitError("truncated zlib header")
    cmf, flg = data[pos], data[pos + 1]
    if (cmf & 0x0F) != 8 or (cmf * 256 + flg) % 31 != 0 or (flg & 0x20):
        raise GitError("bad zlib header")
    return inflate_raw(data, pos + 2)


# --------------------------------------------------------------- object store

PACK_TYPES = {1: "commit", 2: "tree", 3: "blob", 4: "tag"}


def read_varint_le7(data, pos):
    """Reads the little-endian 7-bit varint used by delta size fields."""
    value = 0
    shift = 0
    while True:
        c = data[pos]
        pos += 1
        value |= (c & 0x7F) << shift
        shift += 7
        if not c & 0x80:
            return value, pos


def apply_delta(base, delta):
    """Reconstructs an object from its base and a git delta stream."""
    _, pos = read_varint_le7(delta, 0)
    dst_size, pos = read_varint_le7(delta, pos)
    out = bytearray()
    n = len(delta)
    while pos < n:
        op = delta[pos]
        pos += 1
        if op & 0x80:
            off = 0
            size = 0
            if op & 0x01:
                off = delta[pos]
                pos += 1
            if op & 0x02:
                off |= delta[pos] << 8
                pos += 1
            if op & 0x04:
                off |= delta[pos] << 16
                pos += 1
            if op & 0x08:
                off |= delta[pos] << 24
                pos += 1
            if op & 0x10:
                size = delta[pos]
                pos += 1
            if op & 0x20:
                size |= delta[pos] << 8
                pos += 1
            if op & 0x40:
                size |= delta[pos] << 16
                pos += 1
            if size == 0:
                size = 0x10000
            if off + size > len(base):
                raise GitError("delta copy out of range")
            out += base[off:off + size]
        elif op:
            out += delta[pos:pos + op]
            pos += op
        else:
            raise GitError("reserved delta opcode")
    if len(out) != dst_size:
        raise GitError("delta result size mismatch")
    return bytes(out)


class Pack:
    """One packfile and its v2 index."""

    def __init__(self, idx_path, pack_path):
        with open(idx_path, "rb") as f:
            idx = f.read()
        if idx[:8] != b"\xfftOc\x00\x00\x00\x02":
            raise GitError("unsupported pack index")
        self.count = struct.unpack(">I", idx[8 + 255 * 4:8 + 256 * 4])[0]
        n = self.count
        self.fanout = struct.unpack(">256I", idx[8:8 + 256 * 4])
        base = 8 + 256 * 4
        self.names = idx[base:base + n * 20]
        off_base = base + n * 20 + n * 4
        self.offsets = idx[off_base:off_base + n * 4]
        self.large_base = off_base + n * 4
        self.idx = idx
        self.pack_path = pack_path
        with open(pack_path, "rb") as f:
            self.data = f.read()
        if self.data[:4] != b"PACK" or struct.unpack(">I", self.data[4:8])[0] != 2:
            raise GitError("unsupported packfile")
        self.cache = {}

    def find(self, sha):
        """Returns the pack offset of `sha`, or None."""
        raw = bytes.fromhex(sha)
        lo = self.fanout[raw[0] - 1] if raw[0] else 0
        hi = self.fanout[raw[0]]
        names = self.names
        while lo < hi:
            mid = (lo + hi) // 2
            cur = names[mid * 20:mid * 20 + 20]
            if cur < raw:
                lo = mid + 1
            elif cur > raw:
                hi = mid
            else:
                return self.offset_at(mid)
        return None

    def offset_at(self, i):
        value = struct.unpack(">I", self.offsets[i * 4:i * 4 + 4])[0]
        if value & 0x80000000:
            j = value & 0x7FFFFFFF
            return struct.unpack(
                ">Q", self.idx[self.large_base + j * 8:self.large_base + j * 8 + 8])[0]
        return value

    def iter_names(self):
        for i in range(self.count):
            yield self.names[i * 20:i * 20 + 20].hex()

    def read_at(self, off, repo):
        """Returns (type, payload) for the object stored at `off`."""
        hit = self.cache.get(off)
        if hit is not None:
            return hit
        data = self.data
        c = data[off]
        obj_type = (c >> 4) & 7
        pos = off + 1
        while c & 0x80:
            c = data[pos]
            pos += 1
        if obj_type == 6:
            c = data[pos]
            pos += 1
            rel = c & 0x7F
            while c & 0x80:
                c = data[pos]
                pos += 1
                rel = ((rel + 1) << 7) | (c & 0x7F)
            if rel > off:
                raise GitError("ofs-delta base out of range")
            btype, bdata = self.read_at(off - rel, repo)
            result = (btype, apply_delta(bdata, inflate_zlib(data, pos)))
        elif obj_type == 7:
            base_sha = data[pos:pos + 20].hex()
            pos += 20
            btype, bdata = repo.read_object(base_sha)
            result = (btype, apply_delta(bdata, inflate_zlib(data, pos)))
        else:
            name = PACK_TYPES.get(obj_type)
            if name is None:
                raise GitError("unknown pack object type")
            result = (name, inflate_zlib(data, pos))
        if len(self.cache) > 3000:
            self.cache.clear()
        self.cache[off] = result
        return result


class Repo:
    """A git object database and ref store."""

    def __init__(self, path):
        self.path = path
        self.packs = []
        packdir = os.path.join(path, "objects", "pack")
        if os.path.isdir(packdir):
            for fn in sorted(os.listdir(packdir)):
                if not fn.endswith(".idx"):
                    continue
                pack = os.path.join(packdir, fn[:-4] + ".pack")
                if os.path.exists(pack):
                    self.packs.append(Pack(os.path.join(packdir, fn), pack))
        self.loose_cache = {}
        self.commits = {}
        self._packed_refs = None
        self._all_names = None

    # -- objects

    def loose_path(self, sha):
        return os.path.join(self.path, "objects", sha[:2], sha[2:])

    def read_object(self, sha):
        """Returns (type, payload); raises GitError when the object is absent."""
        hit = self.loose_cache.get(sha)
        if hit is not None:
            return hit
        path = self.loose_path(sha)
        if os.path.exists(path):
            with open(path, "rb") as f:
                raw = inflate_zlib(f.read(), 0)
            nul = raw.find(b"\x00")
            if nul < 0:
                raise GitError("malformed loose object")
            head = raw[:nul].split(b" ")
            if len(head) != 2 or head[0] not in (b"blob", b"tree", b"commit",
                                                 b"tag"):
                raise GitError("malformed loose object header")
            if not head[1] or not head[1].isdigit():
                raise GitError("malformed loose object size")
            obj_type = head[0].decode("ascii")
            size = int(head[1])
            payload = raw[nul + 1:]
            if len(payload) != size:
                raise GitError("loose object size mismatch")
            result = (obj_type, payload)
            if len(self.loose_cache) > 3000:
                self.loose_cache.clear()
            self.loose_cache[sha] = result
            return result
        for pack in self.packs:
            off = pack.find(sha)
            if off is not None:
                return pack.read_at(off, self)
        raise GitError("object not found: " + sha)

    def has_object(self, sha):
        if os.path.exists(self.loose_path(sha)):
            return True
        return any(p.find(sha) is not None for p in self.packs)

    def all_names(self):
        """Every object id in the database, for abbreviation lookups."""
        if self._all_names is None:
            names = set()
            objdir = os.path.join(self.path, "objects")
            if os.path.isdir(objdir):
                for d in os.listdir(objdir):
                    if len(d) != 2 or not is_hex(d):
                        continue
                    sub = os.path.join(objdir, d)
                    if not os.path.isdir(sub):
                        continue
                    for fn in os.listdir(sub):
                        if len(fn) == 38 and is_hex(fn):
                            names.add(d + fn)
            for pack in self.packs:
                names.update(pack.iter_names())
            self._all_names = sorted(names)
        return self._all_names

    def count_objects(self):
        loose = 0
        objdir = os.path.join(self.path, "objects")
        if os.path.isdir(objdir):
            for d in sorted(os.listdir(objdir)):
                if len(d) != 2 or not is_hex(d):
                    continue
                sub = os.path.join(objdir, d)
                if not os.path.isdir(sub):
                    continue
                for fn in os.listdir(sub):
                    if len(fn) == 38 and is_hex(fn) and os.path.isfile(os.path.join(sub, fn)):
                        loose += 1
        return loose, sum(p.count for p in self.packs), len(self.packs)

    # -- refs

    def packed_refs(self):
        if self._packed_refs is None:
            refs = {}
            path = os.path.join(self.path, "packed-refs")
            if os.path.exists(path):
                with open(path, "rb") as f:
                    for line in f.read().split(b"\n"):
                        if not line or line[:1] in (b"#", b"^"):
                            continue
                        sha, _, name = line.partition(b" ")
                        if len(sha) == 40 and is_hex(sha.decode("ascii", "replace")):
                            refs[name.decode("utf-8", "surrogateescape")] = \
                                sha.decode("ascii")
            self._packed_refs = refs
        return self._packed_refs

    def read_ref(self, name, depth=0):
        """Resolves one ref name to an object id, or returns None."""
        if depth > 5 or not valid_ref_name(name):
            return None
        path = os.path.join(self.path, *name.split("/"))
        if (name == "HEAD" or name.startswith("refs/")) and os.path.isfile(path):
            with open(path, "rb") as f:
                content = f.read().strip()
            if content.startswith(b"ref:"):
                return self.read_ref(content[4:].strip().decode(
                    "utf-8", "surrogateescape"), depth + 1)
            text = content.decode("ascii", "replace")
            return text if len(text) == 40 and is_hex(text) else None
        return self.packed_refs().get(name)


def is_hex(s):
    return all(c in "0123456789abcdef" for c in s) and bool(s)


def valid_ref_name(name):
    """Rejects names that could escape the repository directory."""
    if not name or name.startswith("/") or name.endswith("/"):
        return False
    parts = name.split("/")
    return all(p and p not in (".", "..") for p in parts)


# -------------------------------------------------------------- object models

def parse_tree(payload):
    """Returns the tree's entries as (mode bytes, name bytes, hex sha)."""
    entries = []
    i = 0
    n = len(payload)
    while i < n:
        sp = payload.find(b" ", i)
        if sp < 0:
            raise GitError("malformed tree")
        nul = payload.find(b"\x00", sp)
        if nul < 0 or nul + 21 > n:
            raise GitError("malformed tree")
        entries.append((payload[i:sp], payload[sp + 1:nul],
                        payload[nul + 1:nul + 21].hex()))
        i = nul + 21
    return entries


def split_headers(payload):
    """Splits a commit or tag object into its header block and message."""
    i = 0
    n = len(payload)
    while i < n:
        j = payload.find(b"\n", i)
        if j < 0:
            j = n
        if j == i:
            break
        i = j + 1
    return payload[:i], payload[i:]


def header_lines(head):
    """Yields logical header lines, folding continuation lines."""
    lines = head.split(b"\n")
    out = []
    for line in lines:
        if not line:
            continue
        if line.startswith(b" ") and out:
            out[-1] += b"\n" + line[1:]
        else:
            out.append(line)
    return out


class Commit:
    def __init__(self, sha, payload):
        self.sha = sha
        head, message = split_headers(payload)
        self.parents = []
        self.tree = None
        author = committer = b""
        for line in header_lines(head):
            if line.startswith(b"tree "):
                self.tree = line[5:].decode("ascii", "replace").strip()
            elif line.startswith(b"parent "):
                self.parents.append(line[7:].decode("ascii", "replace").strip())
            elif line.startswith(b"author "):
                author = line[7:]
            elif line.startswith(b"committer "):
                committer = line[10:]
        self.author_name = ident_name(author)
        self.author_date = ident_date(author)
        self.date = ident_date(committer)
        self.subject = format_subject(message)


def ident_name(ident):
    """The name part of an ident line: everything before the first '<'."""
    lt = ident.find(b"<")
    if lt < 0:
        return ident.rstrip()
    return ident[:lt].rstrip()


def ident_date(ident):
    """The timestamp of an ident line, as an integer number of seconds."""
    lt = ident.find(b"<")
    gt = ident.find(b">", lt + 1) if lt >= 0 else -1
    if gt < 0:
        return 0
    rest = ident[gt + 1:].split()
    if not rest:
        return 0
    token = rest[0]
    if token[:1] in (b"+", b"-"):
        token = token[1:]
    digits = b""
    for ch in token:
        if 0x30 <= ch <= 0x39:
            digits += bytes((ch,))
        else:
            break
    return int(digits) if digits else 0


def _rstrip_ws(line):
    return line.rstrip(b" \t\r\n\x0b\x0c")


def format_subject(message):
    """The commit subject: blank lines skipped, then lines joined with ' '."""
    lines = message.split(b"\n")
    i = 0
    while i < len(lines) and not _rstrip_ws(lines[i]):
        i += 1
    parts = []
    while i < len(lines):
        stripped = _rstrip_ws(lines[i])
        if not stripped:
            break
        parts.append(stripped)
        i += 1
    return b" ".join(parts)


# ------------------------------------------------------------------- quoting

_ESCAPES = {0x07: b"a", 0x08: b"b", 0x09: b"t", 0x0A: b"n", 0x0B: b"v",
            0x0C: b"f", 0x0D: b"r", 0x22: b"\"", 0x5C: b"\\"}


def quote_path(name):
    """C-style quoting of a path, matching git's core.quotePath default."""
    if all(0x20 <= c < 0x7F and c not in (0x22, 0x5C) for c in name):
        return name
    out = bytearray(b"\"")
    for c in name:
        esc = _ESCAPES.get(c)
        if esc is not None:
            out += b"\\" + esc
        elif c < 0x20 or c >= 0x7F:
            out += b"\\%03o" % c
        else:
            out.append(c)
    out += b"\""
    return bytes(out)


# ------------------------------------------------------------ rev resolution

REF_RULES = ("%s", "refs/%s", "refs/tags/%s", "refs/heads/%s",
             "refs/remotes/%s", "refs/remotes/%s/HEAD")


def lookup_name(repo, name):
    """Resolves a ref name or (abbreviated) object id to an object id."""
    if not name:
        raise GitError("empty revision")
    for rule in REF_RULES:
        candidate = rule % name
        sha = repo.read_ref(candidate)
        if sha is not None:
            return sha
    # Object ids may be written in either case; ids are stored lowercase.
    lowered = name.lower()
    if 4 <= len(name) <= 40 and is_hex(lowered):
        if len(lowered) == 40:
            if repo.has_object(lowered):
                return lowered
            raise GitError("no such object " + name)
        matches = [s for s in repo.all_names() if s.startswith(lowered)]
        if len(matches) == 1:
            return matches[0]
        if len(matches) > 1:
            raise GitError("ambiguous abbreviation " + name)
    raise GitError("unknown revision " + name)


def peel_to_type(repo, sha, want):
    """Dereferences tags and commits until an object of type `want`."""
    for _ in range(32):
        obj_type, payload = repo.read_object(sha)
        if obj_type == want:
            return sha
        if obj_type == "tag":
            sha = tag_target(payload)
        elif obj_type == "commit":
            sha = Commit(sha, payload).tree
            if sha is None:
                raise GitError("commit without tree")
        else:
            raise GitError("cannot peel %s to %s" % (obj_type, want))
    raise GitError("peel loop")


def peel_tags(repo, sha):
    """Dereferences tag objects until a non-tag object."""
    for _ in range(32):
        obj_type, payload = repo.read_object(sha)
        if obj_type != "tag":
            return sha
        sha = tag_target(payload)
    raise GitError("tag loop")


def tag_target(payload):
    head, _ = split_headers(payload)
    for line in header_lines(head):
        if line.startswith(b"object "):
            return line[7:].decode("ascii", "replace").strip()
    raise GitError("tag without object")


def get_commit(repo, sha):
    hit = repo.commits.get(sha)
    if hit is None:
        obj_type, payload = repo.read_object(sha)
        if obj_type != "commit":
            raise GitError("not a commit: " + sha)
        hit = Commit(sha, payload)
        repo.commits[sha] = hit
    return hit


def resolve_rev(repo, spec):
    """Resolves a revision expression to an object id."""
    if not spec:
        raise GitError("empty revision")
    if spec.endswith("}"):
        i = spec.rfind("^{")
        if i > 0:
            base = resolve_rev(repo, spec[:i])
            kind = spec[i + 2:-1]
            if kind == "":
                return peel_tags(repo, base)
            if kind == "object":
                if not repo.has_object(base):
                    raise GitError("no such object " + base)
                return base
            if kind in ("commit", "tree", "blob", "tag"):
                return peel_to_type(repo, base, kind)
            raise GitError("unsupported peel " + kind)
    i = len(spec) - 1
    while i >= 0 and spec[i].isdigit() and spec[i] in "0123456789":
        i -= 1
    if i >= 0 and spec[i] in "^~" and i > 0:
        num = int(spec[i + 1:]) if i + 1 < len(spec) else 1
        if i + 1 == len(spec):
            num = 1
        base = peel_to_type(repo, resolve_rev(repo, spec[:i]), "commit")
        if spec[i] == "^":
            if num == 0:
                return base
            parents = get_commit(repo, base).parents
            if num > len(parents):
                raise GitError("no such parent")
            return parents[num - 1]
        for _ in range(num):
            parents = get_commit(repo, base).parents
            if not parents:
                raise GitError("no such ancestor")
            base = parents[0]
        return base
    return lookup_name(repo, spec)


# ------------------------------------------------------------------- commands

MODE_TYPES = {0o040000: "tree", 0o160000: "commit", 0o120000: "blob",
              0o100000: "blob"}


def entry_type(mode):
    return MODE_TYPES.get(mode & 0o170000, "blob")


def cmd_log(repo, args):
    if not 1 <= len(args) <= 2:
        raise GitError("usage: log <ref> [n]")
    limit = None
    if len(args) == 2:
        if not args[1] or not all(c in "0123456789" for c in args[1]):
            raise GitError("bad count")
        limit = int(args[1])
    start = peel_to_type(repo, resolve_rev(repo, args[0]), "commit")
    # git's default walk: a list kept in decreasing committer-date order, with
    # equal dates left in insertion order.
    queue = [(get_commit(repo, start).date, start)]
    seen = {start}
    out = bytearray()
    shown = 0
    while queue:
        if limit is not None and shown >= limit:
            break
        _, sha = queue.pop(0)
        commit = get_commit(repo, sha)
        out += ("%s " % sha).encode("ascii")
        out += commit.author_name
        out += (" %d " % commit.author_date).encode("ascii")
        out += commit.subject
        out += b"\n"
        shown += 1
        for parent in commit.parents:
            if parent in seen:
                continue
            seen.add(parent)
            date = get_commit(repo, parent).date
            i = 0
            while i < len(queue) and queue[i][0] >= date:
                i += 1
            queue.insert(i, (date, parent))
    return bytes(out)


def tree_at_path(repo, tree_sha, path):
    """Walks `path` from a tree, returning the tree object id it names."""
    if path is None:
        return tree_sha
    parts = path.split("/")
    if any(p in ("", ".", "..") for p in parts):
        raise GitError("bad path")
    current = tree_sha
    for part in parts:
        obj_type, payload = repo.read_object(current)
        if obj_type != "tree":
            raise GitError("not a tree")
        target = part.encode("utf-8", "surrogateescape")
        for mode, name, sha in parse_tree(payload):
            if name == target:
                if int(mode, 8) & 0o170000 != 0o040000:
                    raise GitError("path is not a directory")
                current = sha
                break
        else:
            raise GitError("path not found")
    return current


def cmd_ls_tree(repo, args):
    if not 1 <= len(args) <= 2:
        raise GitError("usage: ls-tree <commit-ish> [path]")
    root = peel_to_type(repo, resolve_rev(repo, args[0]), "tree")
    tree = tree_at_path(repo, root, args[1] if len(args) == 2 else None)
    obj_type, payload = repo.read_object(tree)
    if obj_type != "tree":
        raise GitError("not a tree")
    out = bytearray()
    for mode, name, sha in parse_tree(payload):
        value = int(mode, 8)
        out += b"%06o %s %s\t%s\n" % (value, entry_type(value).encode("ascii"),
                                      sha.encode("ascii"), quote_path(name))
    return bytes(out)


def cmd_cat_file(repo, args):
    if len(args) != 1:
        raise GitError("usage: cat-file <hash>")
    sha = resolve_rev(repo, args[0])
    obj_type, payload = repo.read_object(sha)
    stored = b"%s %d\x00%s" % (obj_type.encode("ascii"), len(payload), payload)
    if sha1_hex(stored) != sha:
        raise GitError("object hash mismatch")
    return b"%s %d\n%s" % (obj_type.encode("ascii"), len(payload), payload)


def collect_tree(repo, tree_sha, prefix, acc):
    """Flattens a tree into {full path: (mode int, sha)} for every blob-ish."""
    for mode, name, sha in parse_tree(repo.read_object(tree_sha)[1]):
        value = int(mode, 8)
        path = prefix + name
        if value & 0o170000 == 0o040000:
            collect_tree(repo, sha, path + b"/", acc)
        else:
            acc[path] = (value, sha)


def cmd_diff(repo, args):
    if len(args) != 2:
        raise GitError("usage: diff <commit1> <commit2>")
    t1 = peel_to_type(repo, resolve_rev(repo, args[0]), "tree")
    t2 = peel_to_type(repo, resolve_rev(repo, args[1]), "tree")
    a = {}
    b = {}
    collect_tree(repo, t1, b"", a)
    collect_tree(repo, t2, b"", b)
    zero = "0" * 40
    lines = []
    for path in set(a) | set(b):
        old = a.get(path)
        new = b.get(path)
        if old == new:
            continue
        if old is None:
            lines.append((path, 0, 0o000000, new[0], zero, new[1], "A"))
        elif new is None:
            lines.append((path, 0, old[0], 0o000000, old[1], zero, "D"))
        else:
            status = "T" if (old[0] ^ new[0]) & 0o170000 else "M"
            lines.append((path, 0, old[0], new[0], old[1], new[1], status))
    out = bytearray()
    for path, _, m1, m2, s1, s2, status in sorted(lines):
        out += b":%06o %06o %s %s %s\t%s\n" % (
            m1, m2, s1.encode("ascii"), s2.encode("ascii"),
            status.encode("ascii"), quote_path(path))
    return bytes(out)


def cmd_rev_parse(repo, args):
    if len(args) != 1:
        raise GitError("usage: rev-parse <ref>")
    return (resolve_rev(repo, args[0]) + "\n").encode("ascii")


def cmd_count_objects(repo, args):
    if args:
        raise GitError("usage: count-objects")
    loose, in_pack, packs = repo.count_objects()
    return b"loose: %d\nin-pack: %d\npacks: %d\n" % (loose, in_pack, packs)


COMMANDS = {"log": cmd_log, "ls-tree": cmd_ls_tree, "cat-file": cmd_cat_file,
            "diff": cmd_diff, "rev-parse": cmd_rev_parse,
            "count-objects": cmd_count_objects}


def run_command(repo, line):
    parts = line.split(" ")
    handler = COMMANDS.get(parts[0])
    if handler is None:
        raise GitError("unknown command")
    return handler(repo, parts[1:])


def main(argv):
    if len(argv) != 3:
        sys.stderr.write("usage: main.py <input dir> <output dir>\n")
        return 2
    in_dir, out_dir = argv[1], argv[2]
    repo = Repo(os.path.join(in_dir, "repo"))
    with open(os.path.join(in_dir, "commands.txt"), "rb") as f:
        raw = f.read()
    lines = raw.split(b"\n")
    if lines and lines[-1] == b"":
        lines.pop()
    os.makedirs(out_dir, exist_ok=True)
    for i, line in enumerate(lines, 1):
        try:
            data = run_command(repo, line.decode("utf-8", "surrogateescape"))
        except Exception:
            data = b"error\n"
        with open(os.path.join(out_dir, "%03d.out" % i), "wb") as f:
            f.write(data)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
