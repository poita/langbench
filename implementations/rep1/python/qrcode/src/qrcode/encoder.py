"""High-level encoding: payload bytes to a finished :class:`QrCode`."""

from __future__ import annotations

from . import reedsolomon
from .errors import DataTooLongError
from .layout import layout_for, place_codewords
from .masking import NUM_MASKS, apply_mask
from .penalty import penalty
from .segments import (
    choose_version,
    encode_segment,
    select_mode,
    to_codewords,
)
from .symbol import QrCode
from .tables import (
    ECC_CODEWORDS_PER_BLOCK,
    NUM_ERROR_CORRECTION_BLOCKS,
    ErrorCorrection,
    data_codewords,
    total_codewords,
)


def add_ecc_and_interleave(data: bytes, version: int, ecl: ErrorCorrection) -> bytes:
    """Split ``data`` into blocks, append Reed-Solomon ECC and interleave."""
    nblocks = NUM_ERROR_CORRECTION_BLOCKS[ecl.index][version - 1]
    ecc_len = ECC_CODEWORDS_PER_BLOCK[ecl.index][version - 1]
    total = total_codewords(version)
    nshort = nblocks - total % nblocks
    short_len = total // nblocks - ecc_len

    blocks = []
    ecc_blocks = []
    pos = 0
    for i in range(nblocks):
        length = short_len + (0 if i < nshort else 1)
        block = data[pos : pos + length]
        pos += length
        blocks.append(block)
        ecc_blocks.append(reedsolomon.remainder(block, ecc_len))

    out = bytearray()
    for i in range(short_len + 1):
        for block in blocks:
            if i < len(block):
                out.append(block[i])
    for i in range(ecc_len):
        for ecc in ecc_blocks:
            out.append(ecc[i])
    return bytes(out)


def encode_bytes(
    data: bytes,
    ecl: ErrorCorrection | str = ErrorCorrection.M,
    mask: int | None = None,
) -> QrCode:
    """Encode raw payload bytes.

    The mode (numeric / alphanumeric / byte) and the smallest fitting version
    are chosen automatically. ``mask`` is 0..7 to force a mask pattern, or
    ``None`` to pick the lowest-penalty one.
    """
    ecl = ErrorCorrection.parse(ecl)
    if mask is not None and not (isinstance(mask, int) and 0 <= mask < NUM_MASKS):
        raise ValueError(f"invalid mask: {mask!r}")
    data = bytes(data)

    mode = select_mode(data)
    version = choose_version(mode, len(data), lambda v: data_codewords(v, ecl))
    if version is None:
        raise DataTooLongError(
            f"{len(data)} bytes do not fit in any version at level {ecl.name}"
        )
    value, nbits = encode_segment(data, mode, version)
    data_cw = to_codewords(value, nbits, data_codewords(version, ecl))
    codewords = add_ecc_and_interleave(data_cw, version, ecl)

    layout = layout_for(version)
    data_rows = place_codewords(layout, codewords)
    ecl_bits = ecl.format_bits
    n = layout.size

    if mask is not None:
        rows = apply_mask(layout, data_rows, ecl_bits, mask)
    else:
        best = None
        for m in range(NUM_MASKS):
            candidate = apply_mask(layout, data_rows, ecl_bits, m)
            score = penalty(candidate, n)
            if best is None or score < best[0]:
                best = (score, m, candidate)
        _, mask, rows = best
    return QrCode(version, ecl, mask, n, tuple(rows))


def encode_text(
    text: str,
    ecl: ErrorCorrection | str = ErrorCorrection.M,
    mask: int | None = None,
) -> QrCode:
    """Encode a string (as UTF-8) into a QR symbol. See :func:`encode_bytes`."""
    return encode_bytes(text.encode("utf-8"), ecl, mask)
