"""The block tree produced by the Codexa parser."""

from __future__ import annotations


class Doc:
    def __init__(self) -> None:
        self.meta: dict[str, str] = {}


class Toc:
    def __init__(self, title: str | None) -> None:
        self.title = title


class Heading:
    def __init__(self, level: int, star: bool) -> None:
        self.level = level
        self.star = star
        self.units: list = []


class Paragraph:
    def __init__(self) -> None:
        self.units: list = []


class Quote:
    def __init__(self) -> None:
        self.children: list = []


class Block:
    """An ``@block`` group; ``attrs`` holds the parsed attributes given."""

    def __init__(self, attrs: dict) -> None:
        self.attrs = attrs
        self.children: list = []


class Item:
    def __init__(self) -> None:
        self.units: list = []
        self.children: list = []


class ListNode:
    def __init__(self, ordered: bool, start: int) -> None:
        self.ordered = ordered
        self.start = start
        self.items: list[Item] = []


class Table:
    """``rows`` is a list of ``("row", [cell units, ...])`` or ``("hrule",)``."""

    def __init__(self, cols: int, aligns: str) -> None:
        self.cols = cols
        self.aligns = aligns
        self.elements: list = []


class Pre:
    def __init__(self) -> None:
        self.lines: list[str] = []


class Figure:
    def __init__(self, height: int, width: int | None) -> None:
        self.height = height
        self.width = width
        self.units: list = []


class Rule:
    pass


class VSpace:
    def __init__(self, height: int) -> None:
        self.height = height


class NewPage:
    pass


class Document:
    """A parsed document: optional ``@doc`` metadata, optional ``@toc``, blocks."""

    def __init__(self) -> None:
        self.meta: dict[str, str] = {"title": "", "author": "", "date": ""}
        self.toc: Toc | None = None
        self.blocks: list = []
        self.footnote_count = 0
