"""Reading a mailbox: an mbox file or a directory of ``.eml`` files."""

from __future__ import annotations

import os
import re
from dataclasses import dataclass

_FROM_LINE = re.compile(rb"^From ", re.MULTILINE)


@dataclass(frozen=True, slots=True)
class RawMessage:
    """The bytes of one message and the id of where it came from."""

    source_id: str
    data: bytes


def _preceded_by_empty_line(data: bytes, pos: int) -> bool:
    """Is the line that ends just before ``data[pos]`` an empty line?"""
    if pos == 0:
        return True
    lf = pos - 1  # index of the previous line's LF
    if lf == 0 or data[lf - 1] == 0x0A:
        return True
    return data[lf - 1] == 0x0D and (lf == 1 or data[lf - 2] == 0x0A)


def split_mbox(data: bytes) -> list[bytes]:
    """Split mbox *data* into message byte strings.

    A separator is a line starting ``From `` that is the first line or follows
    an empty line.  Text before the first separator is discarded, and one of
    the two LFs that end each message is removed.
    """
    starts = [
        m.start() for m in _FROM_LINE.finditer(data) if _preceded_by_empty_line(data, m.start())
    ]
    messages: list[bytes] = []
    for k, start in enumerate(starts):
        end = starts[k + 1] if k + 1 < len(starts) else len(data)
        eol = data.find(b"\n", start)
        begin = len(data) if eol < 0 else eol + 1
        message = data[begin:end]
        if message.endswith(b"\n\n"):
            message = message[:-1]
        messages.append(message)
    return messages


def read_directory(path: str) -> list[RawMessage]:
    """Read every regular ``*.eml`` file directly inside *path*, in byte order."""
    names = [
        name
        for name in os.listdir(path)
        if name.endswith(".eml") and os.path.isfile(os.path.join(path, name))
    ]
    names.sort(key=os.fsencode)
    messages = []
    for name in names:
        with open(os.path.join(path, name), "rb") as fh:
            messages.append(RawMessage(name, fh.read()))
    return messages


def read_mailbox(path: str) -> list[RawMessage]:
    """Read the messages of the mbox file or ``.eml`` directory at *path*.

    mbox messages get the source id ``mbox:<n>`` (1-based).
    """
    if os.path.isdir(path):
        return read_directory(path)
    with open(path, "rb") as fh:
        data = fh.read()
    return [RawMessage(f"mbox:{i}", m) for i, m in enumerate(split_mbox(data), 1)]
