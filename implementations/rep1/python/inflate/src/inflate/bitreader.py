"""LSB-first bit reader over an in-memory byte string."""

from __future__ import annotations

from .errors import InflateError, TruncatedStreamError
from .huffman import HuffmanTable


class BitReader:
    """Reads bits least-significant-bit first from ``data``.

    State is exposed as plain attributes so that the decoder's hot loop can
    keep it in local variables and store it back afterwards.  Invariants
    between calls: ``bitbuf`` holds exactly ``bitcnt`` unconsumed bits, the
    low ``bitcnt % 8`` of which are the remainder of a partially consumed
    byte; ``pos`` is the index of the next byte to load (``pos <= len(data)``).
    """

    __slots__ = ("bitbuf", "bitcnt", "data", "pos")

    def __init__(self, data: bytes) -> None:
        self.data = data
        self.pos = 0
        self.bitbuf = 0
        self.bitcnt = 0

    def _fill(self, n: int) -> None:
        """Load bytes until at least ``n`` bits are buffered, if possible."""
        data, pos = self.data, self.pos
        take = data[pos : pos + (n - self.bitcnt + 7) // 8]
        self.bitbuf |= int.from_bytes(take, "little") << self.bitcnt
        self.bitcnt += 8 * len(take)
        self.pos = pos + len(take)

    def read(self, n: int) -> int:
        """Consume and return an ``n``-bit little-endian number."""
        if self.bitcnt < n:
            self._fill(n)
            if self.bitcnt < n:
                raise TruncatedStreamError("unexpected end of stream")
        value = self.bitbuf & ((1 << n) - 1)
        self.bitbuf >>= n
        self.bitcnt -= n
        return value

    def decode(self, table: HuffmanTable) -> int:
        """Decode one symbol using a single-level ``table``.

        Bits past the end of the stream may be peeked (as zeros) but not
        consumed.
        """
        root = table.root_bits
        if self.bitcnt < root:
            self._fill(root)
        entry = table.entries[self.bitbuf & ((1 << root) - 1)]
        if entry <= 0:
            if entry == 0:
                raise InflateError("invalid Huffman code")
            raise AssertionError("second-level table in single-level decode")
        length = entry & 15
        if length > self.bitcnt:
            raise TruncatedStreamError("unexpected end of stream")
        self.bitbuf >>= length
        self.bitcnt -= length
        return entry >> 4

    def align_to_byte(self) -> None:
        """Discard the rest of the current byte."""
        drop = self.bitcnt & 7
        self.bitbuf >>= drop
        self.bitcnt -= drop

    def read_aligned_bytes(self, n: int) -> bytes:
        """Return the next ``n`` whole bytes; the reader must be aligned."""
        # Hand any whole buffered bytes back to the byte stream.
        self.pos -= self.bitcnt >> 3
        self.bitbuf = 0
        self.bitcnt = 0
        end = self.pos + n
        if end > len(self.data):
            raise TruncatedStreamError("stored block runs past end of stream")
        chunk = self.data[self.pos : end]
        self.pos = end
        return chunk

    def remaining_bytes(self) -> int:
        """Whole bytes not yet (even partially) consumed."""
        return (len(self.data) - self.pos) + (self.bitcnt >> 3)

