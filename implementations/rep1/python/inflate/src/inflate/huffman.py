"""Canonical Huffman decoding tables.

A table is a flat list of ints indexed by the next ``root_bits`` stream bits
(the first bit read is bit 0 of the index, since codes are packed
MSB-first into an LSB-first bit stream).  Entries are:

* ``(symbol << 4) | code_length`` (always positive) for a symbol;
* ``~((offset << 4) | sub_bits)`` (negative) for a link to a second-level
  table that starts at ``offset`` in the same list and is indexed by the next
  ``sub_bits`` bits *after* the root bits; its entries hold the full code
  length;
* ``0`` for a bit pattern that is not a code (only in incomplete codes).

Building a table costs O(n_symbols + 2**root_bits) plus the (small) second
level.
"""

from __future__ import annotations

from functools import cache
from typing import NamedTuple

from .errors import InflateError
from .tables import MAX_CODE_LENGTH, fixed_dist_lengths, fixed_litlen_lengths

_REV8 = tuple(int(f"{i:08b}"[::-1], 2) for i in range(256))


class HuffmanTable(NamedTuple):
    """A decoding table plus facts about the code it was built from."""

    entries: list[int]
    root_bits: int
    used: int  #: number of symbols with a nonzero length
    complete: bool  #: Kraft sum is exactly 1
    single_bit: bool  #: exactly one code, of length 1


def _reverse(code: int, length: int) -> int:
    """Reverse the low ``length`` bits of ``code`` (``length`` <= 16)."""
    return ((_REV8[code & 255] << 8) | _REV8[code >> 8]) >> (16 - length)


def build_table(lengths: list[int] | tuple[int, ...], max_root: int) -> HuffmanTable:
    """Build a decoding table for the canonical code with the given lengths.

    ``lengths[s]`` is the code length of symbol ``s`` (0 = unused).  The root
    table is ``min(max_root, longest code)`` bits wide.  Raises
    :class:`InflateError` if the code is over-subscribed; incomplete codes are
    accepted (unused patterns decode to 0) and reported via ``complete``.
    """
    count = [0] * (MAX_CODE_LENGTH + 1)
    for length in lengths:
        count[length] += 1
    used = len(lengths) - count[0]
    count[0] = 0

    left = 1
    max_len = 0
    for length in range(1, MAX_CODE_LENGTH + 1):
        left = (left << 1) - count[length]
        if left < 0:
            raise InflateError("over-subscribed Huffman code")
        if count[length]:
            max_len = length

    next_code = [0] * (MAX_CODE_LENGTH + 2)
    code = 0
    for length in range(1, MAX_CODE_LENGTH + 1):
        code = (code + count[length - 1]) << 1
        next_code[length] = code

    root = max(1, min(max_root, max_len))
    root_size = 1 << root
    entries = [0] * root_size
    long_codes: list[tuple[int, int, int]] = []  # (reversed code, length, symbol)

    for symbol, length in enumerate(lengths):
        if not length:
            continue
        rev = _reverse(next_code[length], length)
        next_code[length] += 1
        if length <= root:
            entries[rev::1 << length] = [(symbol << 4) | length] * (root_size >> length)
        else:
            long_codes.append((rev, length, symbol))

    if long_codes:
        mask = root_size - 1
        sub_len: dict[int, int] = {}
        for rev, length, _ in long_codes:
            prefix = rev & mask
            if sub_len.get(prefix, 0) < length:
                sub_len[prefix] = length
        offsets: dict[int, tuple[int, int]] = {}
        for prefix, longest in sub_len.items():
            sub_bits = longest - root
            offset = len(entries)
            entries.extend([0] * (1 << sub_bits))
            entries[prefix] = ~((offset << 4) | sub_bits)
            offsets[prefix] = (offset, 1 << sub_bits)
        for rev, length, symbol in long_codes:
            offset, size = offsets[rev & mask]
            step = 1 << (length - root)
            start = offset + (rev >> root)
            entries[start : offset + size : step] = [(symbol << 4) | length] * (size // step)

    return HuffmanTable(entries, root, used, left == 0, used == 1 and max_len == 1)


@cache
def fixed_tables() -> tuple[HuffmanTable, HuffmanTable]:
    """The (literal/length, distance) tables of fixed-Huffman blocks."""
    return (
        build_table(fixed_litlen_lengths(), 10),
        build_table(fixed_dist_lengths(), 8),
    )
