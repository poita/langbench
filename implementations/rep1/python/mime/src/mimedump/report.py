"""Rendering parsed messages in the normalised text dump format."""

from __future__ import annotations

import os
from dataclasses import dataclass

from .checksum import adler32_hex
from .mailbox import RawMessage, read_mailbox
from .message import ADDRESS_FIELDS, Message, parse_message
from .parts import Kind, Part

_ESCAPES = {0x5C: "\\\\", 0x0A: "\\n", 0x0D: "\\r", 0x09: "\\t", 0x22: '\\"'}
for _c in (*range(0x20), 0x7F, *range(0x80, 0xA0)):
    _ESCAPES.setdefault(_c, f"\\x{_c:02x}")


def esc(s: str) -> str:
    """Escape *s* for the dump: backslash, quotes, and control characters."""
    return s.translate(_ESCAPES)


def q(s: str) -> str:
    """Escape and double-quote *s*."""
    return f'"{esc(s)}"'


def format_number(n: int) -> str:
    """Four-digit, zero-padded message number."""
    return f"{n:04d}"


def attachment_path(number: int, part: Part) -> str:
    """Output-relative path of an attachment's decoded bytes."""
    return f"parts/{format_number(number)}/{part.index:03d}.bin"


def _structure_line(msg: Message, part: Part, depth: int) -> str:
    attrs: list[str] = []
    if part.charset is not None:
        attrs.append(f"charset={part.charset}")
    attrs.append(f"cte={part.encoding}")
    if part.disposition is not None:
        attrs.append(f"disposition={part.disposition}")
    if part.filename is not None:
        attrs.append(f"filename={q(part.filename)}")
    if part.kind is Kind.MULTIPART:
        assert part.boundary is not None and part.preamble is not None
        attrs.append(f"boundary={q(part.boundary)}")
        attrs.append(f"parts={len(part.children)}")
        attrs.append(f"preamble={len(part.preamble)}")
        epilogue = "none" if part.epilogue is None else str(len(part.epilogue))
        attrs.append(f"epilogue={epilogue}")
    elif part.kind is Kind.MESSAGE:
        attrs.append(f"parts={len(part.children)}")
    else:
        role = "text" if part is msg.text_part else "html" if part is msg.html_part else "attachment"
        attrs.append(f"size={len(part.content)}")
        attrs.append(f"adler32={adler32_hex(part.content)}")
        attrs.append(f"role={role}")
    return f"{'  ' * depth}{part.index} {part.content_type} {' '.join(attrs)}"


def _depths(root: Part) -> dict[int, int]:
    depths: dict[int, int] = {}
    stack = [(root, 0)]
    while stack:
        part, depth = stack.pop()
        depths[part.index] = depth
        stack.extend((c, depth + 1) for c in part.children)
    return depths


def _body_lines(label: str, part: Part | None) -> list[str]:
    if part is None:
        return [f"{label} none"]
    text = part.text or ""
    lines = [f"{label} {part.index} chars {len(text)}"]
    pieces = text.split("\n")
    if pieces[-1] == "":
        pieces.pop()
    lines.extend(f"| {esc(piece)}" for piece in pieces)
    return lines


def render_message(msg: Message, number: int, source_id: str) -> str:
    """Render the seven-section dump of *msg* (the text of ``messages/NNNN.txt``)."""
    sections: list[list[str]] = []
    sections.append(["[message]", f"id {format_number(number)}", f"source {q(source_id)}"])
    sections.append(
        ["[headers]"] + [f"{h.key}: {q(h.display_value)}" for h in msg.headers]
    )
    lines = ["[addresses]"]
    for name in ADDRESS_FIELDS:
        for k, addr in enumerate(msg.addresses(name)):
            lines.append(f"{name} {k} display={q(addr.display)} spec={q(addr.spec)}")
    sections.append(lines)
    lines = ["[date]"]
    raw = msg.date_raw
    if raw is None:
        lines.append("none")
    else:
        lines.append(f"raw {q(raw)}")
        date = msg.date
        if date is None:
            lines.append("valid no")
        else:
            lines += ["valid yes", f"utc {date.utc}", f"offset {date.offset}", f"epoch {date.epoch}"]
    sections.append(lines)
    depths = _depths(msg.root)
    sections.append(["[structure]"] + [_structure_line(msg, p, depths[p.index]) for p in msg.parts])
    sections.append(["[body]"] + _body_lines("text", msg.text_part) + _body_lines("html", msg.html_part))
    lines = ["[attachments]"]
    for p in msg.attachments:
        filename = "-" if p.filename is None else q(p.filename)
        lines.append(
            f"{p.index} type={p.content_type} filename={filename} size={len(p.content)} "
            f"adler32={adler32_hex(p.content)} file={attachment_path(number, p)}"
        )
    sections.append(lines)
    return "\n\n".join("\n".join(s) for s in sections) + "\n"


@dataclass(frozen=True, slots=True)
class SummaryEntry:
    """One line of ``summary.txt``."""

    number: int
    source_id: str
    msg: Message

    def render(self) -> str:
        m = self.msg
        text = "-" if m.text_part is None else str(m.text_part.index)
        html = "-" if m.html_part is None else str(m.html_part.index)
        return (
            f"{format_number(self.number)} source={q(self.source_id)} bytes={m.size} "
            f"parts={len(m.parts)} attachments={len(m.attachments)} text={text} html={html}"
        )


def _write(path: str, data: bytes) -> None:
    with open(path, "wb") as fh:
        fh.write(data)


def write_message(output_dir: str, number: int, source_id: str, msg: Message) -> None:
    """Write a message's dump and its attachments below *output_dir*."""
    _write(
        os.path.join(output_dir, "messages", f"{format_number(number)}.txt"),
        render_message(msg, number, source_id).encode("utf-8"),
    )
    if msg.attachments:
        os.makedirs(os.path.join(output_dir, "parts", format_number(number)), exist_ok=True)
        for part in msg.attachments:
            _write(os.path.join(output_dir, attachment_path(number, part)), part.content)


def dump_messages(raw_messages: list[RawMessage], output_dir: str) -> None:
    """Parse *raw_messages* and write the whole report into *output_dir*."""
    os.makedirs(os.path.join(output_dir, "messages"), exist_ok=True)
    summary = [f"messages {len(raw_messages)}"]
    for number, raw in enumerate(raw_messages, 1):
        msg = parse_message(raw.data)
        write_message(output_dir, number, raw.source_id, msg)
        summary.append(SummaryEntry(number, raw.source_id, msg).render())
    _write(os.path.join(output_dir, "summary.txt"), ("\n".join(summary) + "\n").encode("utf-8"))


def dump_mailbox(input_path: str, output_dir: str) -> None:
    """Read the mailbox at *input_path* and write its report to *output_dir*."""
    dump_messages(read_mailbox(input_path), output_dir)
