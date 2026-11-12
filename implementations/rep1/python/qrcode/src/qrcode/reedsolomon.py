"""Reed-Solomon error correction over GF(2^8) (primitive polynomial 0x11D)."""

from __future__ import annotations

from functools import lru_cache

_PRIMITIVE = 0x11D


def _build_tables() -> tuple[list[int], list[int]]:
    exp = [0] * 510
    log = [0] * 256
    x = 1
    for i in range(255):
        exp[i] = x
        log[x] = i
        x <<= 1
        if x & 0x100:
            x ^= _PRIMITIVE
    for i in range(255, 510):
        exp[i] = exp[i - 255]
    return exp, log


_EXP, _LOG = _build_tables()


def gf_multiply(a: int, b: int) -> int:
    """Multiply two field elements."""
    if a == 0 or b == 0:
        return 0
    return _EXP[_LOG[a] + _LOG[b]]


def generator_polynomial(degree: int) -> list[int]:
    """Coefficients of ``prod_{i<degree} (x - 2^i)``, highest degree first.

    The leading coefficient (always 1) is omitted, so the result has
    ``degree`` entries.
    """
    if not 1 <= degree <= 255:
        raise ValueError("degree out of range")
    coeffs = [1]  # highest degree first, monic
    root = 1
    for _ in range(degree):
        nxt = coeffs + [0]
        for j, c in enumerate(coeffs):
            nxt[j + 1] ^= gf_multiply(c, root)
        coeffs = nxt
        root = gf_multiply(root, 2)
    return coeffs[1:]


@lru_cache(maxsize=None)
def _factor_table(degree: int) -> tuple[int, ...]:
    """For each feedback byte ``f``, the generator times ``f`` packed as an int.

    Packing the ``degree`` bytes of the shift register into one Python int
    lets a whole division step be a couple of big-int operations.
    """
    gen = generator_polynomial(degree)
    table = []
    for f in range(256):
        table.append(int.from_bytes(bytes(gf_multiply(g, f) for g in gen), "big"))
    return tuple(table)


def remainder(data: bytes, degree: int) -> bytes:
    """ECC codewords: remainder of ``data(x) * x^degree`` by the generator."""
    table = _factor_table(degree)
    shift = 8 * (degree - 1)
    low = (1 << shift) - 1
    reg = 0
    for d in data:
        f = d ^ (reg >> shift)
        reg = ((reg & low) << 8) ^ table[f]
    return reg.to_bytes(degree, "big")
