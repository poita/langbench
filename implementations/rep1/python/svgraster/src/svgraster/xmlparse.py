"""A tiny non-validating XML parser, sufficient for SVG documents.

Only elements and attributes are kept.  Character data, comments, processing
instructions, DOCTYPE declarations and CDATA sections are skipped.  Namespace
prefixes are stripped from element and attribute names.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field

__all__ = ["Element", "XMLError", "parse_xml", "resolve_entities"]


class XMLError(ValueError):
    """Raised when the document has no element at all."""


@dataclass(eq=False)
class Element:
    """An XML element: stripped tag name, attributes and child elements."""

    tag: str
    attrs: dict[str, str] = field(default_factory=dict)
    children: list["Element"] = field(default_factory=list)
    # Lazily parsed ``style`` declarations (see :mod:`svgraster.values`).
    style: dict[str, str] | None = None


_ENTITY = re.compile(r"&(?:(amp|lt|gt|quot|apos)|#([0-9]+)|#[xX]([0-9a-fA-F]+));")
_NAMED = {"amp": "&", "lt": "<", "gt": ">", "quot": '"', "apos": "'"}
_NAME_END = re.compile(r"[\s/>]")
_ATTR = re.compile(r"""\s*([^\s=/>]+)\s*=\s*(?:"([^"]*)"|'([^']*)')""")


def _entity_sub(match: re.Match[str]) -> str:
    named, dec, hexa = match.groups()
    if named:
        return _NAMED[named]
    try:
        return chr(int(dec) if dec is not None else int(hexa, 16))
    except (ValueError, OverflowError):
        return match.group(0)


def resolve_entities(value: str) -> str:
    """Resolve the five predefined entities and numeric character references."""
    if "&" not in value:
        return value
    return _ENTITY.sub(_entity_sub, value)


def _strip_prefix(name: str) -> str:
    return name.rsplit(":", 1)[-1]


def _skip_doctype(text: str, pos: int) -> int:
    """Return the index just past a ``<!DOCTYPE ...>`` starting at *pos*."""
    n = len(text)
    i = pos + 9
    quote = ""
    depth = 0
    while i < n:
        c = text[i]
        if quote:
            if c == quote:
                quote = ""
        elif c in "\"'":
            quote = c
        elif c == "[":
            depth += 1
        elif c == "]":
            depth -= 1
        elif c == ">" and depth <= 0:
            return i + 1
        i += 1
    return n


def _parse_tag(text: str, pos: int) -> tuple[str, dict[str, str], bool, int]:
    """Parse a start tag at *pos* (``text[pos] == '<'``).

    Returns ``(name, attrs, self_closing, next_pos)``.
    """
    n = len(text)
    m = _NAME_END.search(text, pos + 1)
    name_end = m.start() if m else n
    name = _strip_prefix(text[pos + 1:name_end])
    attrs: dict[str, str] = {}
    i = name_end
    while i < n:
        while i < n and text[i] in " \t\r\n":
            i += 1
        if i >= n:
            break
        c = text[i]
        if c == ">":
            return name, attrs, False, i + 1
        if c == "/":
            j = i + 1
            while j < n and text[j] in " \t\r\n":
                j += 1
            if j < n and text[j] == ">":
                return name, attrs, True, j + 1
            i += 1
            continue
        am = _ATTR.match(text, i)
        if am is None:
            i += 1  # skip garbage
            continue
        raw = am.group(2) if am.group(2) is not None else am.group(3)
        attrs[_strip_prefix(am.group(1))] = resolve_entities(raw)
        i = am.end()
    return name, attrs, False, n


def parse_xml(text: str) -> Element:
    """Parse *text* and return the document element.

    Raises :class:`XMLError` if no start tag is found.
    """
    n = len(text)
    pos = 0
    root: Element | None = None
    stack: list[Element] = []
    while True:
        pos = text.find("<", pos)
        if pos < 0:
            break
        if text.startswith("<!--", pos):
            end = text.find("-->", pos + 4)
            pos = n if end < 0 else end + 3
        elif text.startswith("<![CDATA[", pos):
            end = text.find("]]>", pos + 9)
            pos = n if end < 0 else end + 3
        elif text.startswith("<?", pos):
            end = text.find("?>", pos + 2)
            pos = n if end < 0 else end + 2
        elif text.startswith("<!DOCTYPE", pos):
            pos = _skip_doctype(text, pos)
        elif text.startswith("<!", pos):
            end = text.find(">", pos + 2)
            pos = n if end < 0 else end + 1
        elif text.startswith("</", pos):
            end = text.find(">", pos + 2)
            pos = n if end < 0 else end + 1
            if stack:
                stack.pop()
        else:
            name, attrs, closed, pos = _parse_tag(text, pos)
            el = Element(name, attrs)
            if stack:
                stack[-1].children.append(el)
            elif root is None:
                root = el
            if root is None:  # pragma: no cover - defensive
                root = el
            if not closed:
                stack.append(el)
            if not stack and root is not None and closed:
                # a self-closing document element: nothing more matters
                break
    if root is None:
        raise XMLError("no element found")
    return root
