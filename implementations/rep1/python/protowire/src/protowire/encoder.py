"""Wire-format encoder: a :class:`~protowire.values.Message` tree to bytes.

Encoding runs in two passes over the tree. The first computes the size of
every sub-message (recorded in pre-order); the second writes the bytes
straight into one buffer, reading those sizes back in the same order. No
sub-message is ever encoded into a temporary buffer, so the work is linear in
the output size regardless of nesting depth.
"""

from __future__ import annotations

from collections.abc import Iterator
from typing import Any

from .schema import FieldDesc
from .scalars import FIXED32, VARINT
from .values import Message
from .wire import put_varint, varint_size


def encode_message(msg: Message) -> bytes:
    """Encode ``msg`` in canonical form: fields by number, defaults omitted,
    repeated numeric fields packed, every varint minimal.

    Raises :class:`~protowire.errors.ProtowireError` if a string value cannot
    be represented as UTF-8.
    """
    sizes: list[int] = []
    total = _measure(msg, sizes)
    out = bytearray()
    it = iter(sizes)
    next(it)  # the root's own size
    _write(msg, out, it)
    assert len(out) == total
    return bytes(out)


def _emitted(msg: Message) -> list[tuple[FieldDesc, Any]]:
    """The (field, value) pairs that appear on the wire, by field number."""
    by_number = msg.desc.by_number
    out = []
    values = msg.values
    for number in sorted(values):
        fd = by_number[number]
        v = values[number]
        if fd.repeated:
            if not v:
                continue
        elif fd.scalar is not None and not v:  # default: 0, False, "", b""
            continue
        out.append((fd, v))
    return out


def _measure(msg: Message, sizes: list[int]) -> int:
    """Return the encoded size of ``msg``; append every sub-message's size
    (including ``msg``'s own) to ``sizes`` in pre-order."""
    slot = len(sizes)
    sizes.append(0)
    total = 0
    for fd, v in _emitted(msg):
        scalar = fd.scalar
        tag_len = len(fd.tag)
        if scalar is None:
            for sub in v if fd.repeated else (v,):
                n = _measure(sub, sizes)
                total += tag_len + varint_size(n) + n
        elif fd.repeated and scalar.packable:
            to_wire = scalar.to_wire
            if scalar.wire_type == VARINT:
                payload = sum(varint_size(to_wire(x)) for x in v)
            else:
                payload = len(v) * scalar.fixed_size
            total += tag_len + varint_size(payload) + payload
        elif scalar.packable:
            if scalar.wire_type == VARINT:
                total += tag_len + varint_size(scalar.to_wire(v))
            else:
                total += tag_len + scalar.fixed_size
        else:  # string / bytes
            to_wire = scalar.to_wire
            for x in v if fd.repeated else (v,):
                n = len(to_wire(x))
                total += tag_len + varint_size(n) + n
    sizes[slot] = total
    return total


def _write(msg: Message, out: bytearray, sizes: Iterator[int]) -> None:
    """Write the body of ``msg`` to ``out``.

    ``sizes`` yields the pre-order size entries; the entry for ``msg`` itself
    has already been consumed by the caller.
    """
    for fd, v in _emitted(msg):
        scalar = fd.scalar
        if scalar is None:
            for sub in v if fd.repeated else (v,):
                out += fd.tag
                put_varint(out, next(sizes))  # sub's size: next pre-order entry
                _write(sub, out, sizes)
        elif fd.repeated and scalar.packable:
            to_wire = scalar.to_wire
            if scalar.wire_type == VARINT:
                payload = sum(varint_size(to_wire(x)) for x in v)
                out += fd.packed_tag
                put_varint(out, payload)
                for x in v:
                    put_varint(out, to_wire(x))
            else:
                size = scalar.fixed_size
                out += fd.packed_tag
                put_varint(out, len(v) * size)
                for x in v:
                    out += to_wire(x).to_bytes(size, "little")
        elif scalar.packable:
            out += fd.tag
            if scalar.wire_type == VARINT:
                put_varint(out, scalar.to_wire(v))
            else:
                out += scalar.to_wire(v).to_bytes(scalar.fixed_size, "little")
        else:
            to_wire = scalar.to_wire
            for x in v if fd.repeated else (v,):
                b = to_wire(x)
                out += fd.tag
                put_varint(out, len(b))
                out += b

