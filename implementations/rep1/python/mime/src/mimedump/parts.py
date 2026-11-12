"""Building the MIME part tree of a message."""

from __future__ import annotations

import enum
import re
from dataclasses import dataclass, field
from functools import cached_property

from .charsets import decode, normalize_charset
from .headers import Header, find_header, parse_headers
from .structured import StructuredValue, parse_structured
from .textutil import normalize_newlines
from .transfer import decode_body


class Kind(enum.Enum):
    """How a part is structured."""

    MULTIPART = "multipart"  #: a ``multipart/*`` part with a usable boundary
    MESSAGE = "message"  #: a ``message/rfc822`` part holding one message
    LEAF = "leaf"  #: everything else


@dataclass(slots=True, eq=False)
class Part:
    """One node of the MIME tree (the message itself is part 0)."""

    index: int
    headers: list[Header]
    maintype: str
    subtype: str
    encoding: str
    kind: Kind
    #: Effective ``Content-Type`` parameters.
    params: dict[str, str] = field(default_factory=dict)
    #: Disposition type, or ``None`` without a ``Content-Disposition`` header.
    disposition: str | None = None
    filename: str | None = None
    #: Normalised charset name; only set for ``text/*`` parts.
    charset: str | None = None
    boundary: str | None = None
    children: list[Part] = field(default_factory=list)
    preamble: bytes | None = None
    #: Bytes after the close delimiter; ``None`` if there was none.
    epilogue: bytes | None = None
    #: Decoded body of a leaf part.
    content: bytes = b""
    _text: str | None = field(default=None, repr=False)

    @property
    def content_type(self) -> str:
        return f"{self.maintype}/{self.subtype}"

    @property
    def is_leaf(self) -> bool:
        return self.kind is Kind.LEAF

    @property
    def text(self) -> str | None:
        """The decoded text of a ``text/*`` leaf, ``None`` for other parts."""
        if self.maintype != "text" or not self.is_leaf:
            return None
        if self._text is None:
            self._text = decode(self.content, self.charset or "us-ascii")
        return self._text

    def header(self, name: str) -> Header | None:
        """The first header called *name* (lower-case), or ``None``."""
        return find_header(self.headers, name)


_TOKEN = r'[^ \t()<>@,;:\\"/\[\]?=]+'
_TYPE = re.compile(rf"({_TOKEN})/({_TOKEN})")


def _delimiter_pattern(boundary: str) -> re.Pattern[bytes]:
    return re.compile(
        rb"^--" + re.escape(boundary.encode("utf-8")) + rb"(--)?[ \t]*$", re.MULTILINE
    )


def _trim_lf(data: bytes) -> bytes:
    return data[:-1] if data.endswith(b"\n") else data


def _split_multipart(body: bytes, boundary: str) -> tuple[bytes, list[bytes], bytes | None]:
    """Return ``(preamble, child byte strings, epilogue)`` for a multipart body."""
    delimiters = list(_delimiter_pattern(boundary).finditer(body))
    if not delimiters:
        return body, [], None
    preamble = _trim_lf(body[:delimiters[0].start()])
    children: list[bytes] = []
    epilogue: bytes | None = None
    for k, d in enumerate(delimiters):
        after = d.end() + 1 if body[d.end():d.end() + 1] == b"\n" else d.end()
        if d.group(1) is not None:  # close delimiter
            epilogue = body[after:]
            break
        if k + 1 < len(delimiters):
            children.append(_trim_lf(body[after:delimiters[k + 1].start()]))
        else:
            children.append(_trim_lf(body[after:]))
    return preamble, children, epilogue


def _build(data: bytes, parent_type: str | None, parts: list[Part]) -> Part:
    headers, body = parse_headers(data)

    ct_header = find_header(headers, "content-type")
    ct = parse_structured(ct_header.value) if ct_header else StructuredValue("")
    m = _TYPE.fullmatch(ct.value)
    if m:
        maintype, subtype = m.group(1), m.group(2)
    elif parent_type == "multipart/digest":
        maintype, subtype = "message", "rfc822"
    else:
        maintype, subtype = "text", "plain"

    cte_header = find_header(headers, "content-transfer-encoding")
    encoding = parse_structured(cte_header.value).value if cte_header else "7bit"

    disposition = None
    filename = None
    cd_header = find_header(headers, "content-disposition")
    if cd_header:
        cd = parse_structured(cd_header.value)
        disposition = cd.value or "inline"
        filename = cd.params.get("filename")
    if filename is None:
        filename = ct.params.get("name")

    charset = None
    if maintype == "text":
        charset = normalize_charset(ct.params["charset"]) if "charset" in ct.params else "us-ascii"

    boundary = ct.params.get("boundary") or None
    if maintype == "multipart" and boundary:
        kind = Kind.MULTIPART
    elif maintype == "message" and subtype == "rfc822":
        kind = Kind.MESSAGE
    else:
        kind = Kind.LEAF

    part = Part(
        index=len(parts),
        headers=headers,
        maintype=maintype,
        subtype=subtype,
        encoding=encoding,
        kind=kind,
        params=ct.params,
        disposition=disposition,
        filename=filename,
        charset=charset,
    )
    parts.append(part)

    if kind is Kind.MULTIPART:
        assert boundary is not None
        part.boundary = boundary
        this_type = f"{maintype}/{subtype}"
        part.preamble, child_data, part.epilogue = _split_multipart(body, boundary)
        part.children = [_build(c, this_type, parts) for c in child_data]
    elif kind is Kind.MESSAGE:
        inner = normalize_newlines(decode_body(body, encoding))
        part.children = [_build(inner, None, parts)]
    else:
        part.content = decode_body(body, encoding)
    return part


def build_parts(data: bytes) -> list[Part]:
    """Parse *data* (a message with LF line endings) into a pre-order part list."""
    parts: list[Part] = []
    _build(data, None, parts)
    return parts
