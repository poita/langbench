"""CRC-32 (reflected polynomial 0xEDB88320), table driven (SPEC §3)."""

_POLY = 0xEDB88320


def _make_table() -> tuple[int, ...]:
    table = []
    for n in range(256):
        c = n
        for _ in range(8):
            c = (c >> 1) ^ _POLY if c & 1 else c >> 1
        table.append(c)
    return tuple(table)


_TABLE = _make_table()


def crc32(data: bytes, crc: int = 0) -> int:
    """Return the CRC-32 of ``data``.

    ``crc`` is the CRC of any preceding data, so a checksum can be computed
    piecewise: ``crc32(b, crc32(a)) == crc32(a + b)``.
    """
    c = crc ^ 0xFFFFFFFF
    table = _TABLE
    for b in data:
        c = table[(c ^ b) & 0xFF] ^ (c >> 8)
    return c ^ 0xFFFFFFFF
