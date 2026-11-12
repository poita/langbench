"""Wire-format decoder: bytes to a :class:`~protowire.values.Message` tree."""

from __future__ import annotations

from .errors import ProtowireError
from .schema import MessageDesc
from .scalars import FIXED32, FIXED64, LEN, START_GROUP, VARINT
from .values import Message
from .wire import read_length, read_tag, read_varint, skip_field, skip_group, skip_payload


def decode_message(desc: MessageDesc, data: bytes) -> Message:
    """Decode ``data`` as a message of type ``desc``.

    Unknown fields and fields with a mismatched wire type are skipped.
    Raises :class:`ProtowireError` on malformed data.
    """
    msg = Message(desc)
    _decode_into(msg, bytes(data), 0, len(data))
    return msg


def _decode_into(msg: Message, data: bytes, pos: int, end: int) -> None:
    """Decode ``data[pos:end]`` into ``msg``, merging with existing values."""
    by_number = msg.desc.by_number
    values = msg.values
    while pos < end:
        number, wt, pos = read_tag(data, pos, end)
        fd = by_number.get(number)
        if fd is None:
            pos = skip_field(data, pos, end, number, wt)
            continue

        scalar = fd.scalar
        if scalar is None:  # message-typed field
            if wt != LEN:
                pos = skip_field(data, pos, end, number, wt)
                continue
            n, pos = read_length(data, pos, end)
            if fd.repeated:
                sub = Message(fd.message)
                values.setdefault(number, []).append(sub)
            else:
                sub = values.get(number)
                if sub is None:
                    sub = values[number] = Message(fd.message)
            _decode_into(sub, data, pos, pos + n)
            pos += n
            continue

        swt = scalar.wire_type
        if wt == swt:
            if swt == VARINT:
                raw, pos = read_varint(data, pos, end)
            elif swt == LEN:
                n, pos = read_length(data, pos, end)
                raw = data[pos : pos + n]
                pos += n
            else:
                size = 4 if swt == FIXED32 else 8
                if end - pos < size:
                    raise ProtowireError("truncated fixed-size value")
                raw = int.from_bytes(data[pos : pos + size], "little")
                pos += size
            value = scalar.from_wire(raw)
            if fd.repeated:
                values.setdefault(number, []).append(value)
            else:
                values[number] = value
        elif wt == LEN and fd.repeated and swt != LEN:
            n, pos = read_length(data, pos, end)
            stop = pos + n
            items = values.setdefault(number, [])
            _decode_packed(items, scalar, data, pos, stop)
            pos = stop
        else:
            pos = skip_field(data, pos, end, number, wt)


def _decode_packed(items: list, scalar, data: bytes, pos: int, stop: int) -> None:
    """Append the elements of a packed payload ``data[pos:stop]`` to ``items``."""
    from_wire = scalar.from_wire
    if scalar.wire_type == VARINT:
        while pos < stop:
            b = data[pos]
            if b < 0x80:  # fast path: one-byte varint
                items.append(from_wire(b))
                pos += 1
            else:
                raw, pos = read_varint(data, pos, stop)
                items.append(from_wire(raw))
    else:
        size = scalar.fixed_size
        if (stop - pos) % size:
            raise ProtowireError("packed fixed-size payload has a partial element")
        from_bytes = int.from_bytes
        for i in range(pos, stop, size):
            items.append(from_wire(from_bytes(data[i : i + size], "little")))
