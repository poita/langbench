"""Syntax-tree node types shared by the block parser, inline parser and renderer.

The tree is a classic first-child / next-sibling structure with doubly linked
siblings, so that wrapping or splicing a run of siblings costs O(1).

Block nodes (:class:`Block`) additionally carry a ``parent`` pointer and the
bookkeeping used while the block structure is being built.  Inline nodes
(:class:`Node` and :class:`LinkNode`) do not use ``parent``.
"""

from __future__ import annotations

from collections.abc import Iterator

# --- node types -------------------------------------------------------------

# Containers and leaves of the block structure.
DOCUMENT = 0
BLOCK_QUOTE = 1
LIST = 2
ITEM = 3
PARAGRAPH = 4
HEADING = 5
THEMATIC_BREAK = 6
CODE_BLOCK = 7

# Inline nodes.
TEXT = 8
SOFTBREAK = 9
LINEBREAK = 10
CODE = 11
EMPH = 12
STRONG = 13
LINK = 14
IMAGE = 15

TYPE_NAMES = {
    DOCUMENT: "document",
    BLOCK_QUOTE: "block_quote",
    LIST: "list",
    ITEM: "item",
    PARAGRAPH: "paragraph",
    HEADING: "heading",
    THEMATIC_BREAK: "thematic_break",
    CODE_BLOCK: "code_block",
    TEXT: "text",
    SOFTBREAK: "softbreak",
    LINEBREAK: "linebreak",
    CODE: "code",
    EMPH: "emph",
    STRONG: "strong",
    LINK: "link",
    IMAGE: "image",
}


class Node:
    """A node of the document tree.

    Attributes:
        type: One of the module-level type constants (``TEXT``, ``EMPH``, ...).
        literal: Text payload for text and code nodes (empty otherwise).
        parent: Parent node (only maintained for block nodes).
        next, prev: Sibling links.
        first_child, last_child: Child links.
    """

    __slots__ = ("type", "literal", "parent", "next", "prev", "first_child", "last_child")

    def __init__(self, type: int, literal: str = "") -> None:
        self.type = type
        self.literal = literal
        self.parent = None
        self.next = None
        self.prev = None
        self.first_child = None
        self.last_child = None

    @property
    def type_name(self) -> str:
        """Human-readable name of :attr:`type`."""
        return TYPE_NAMES[self.type]

    def children(self) -> Iterator[Node]:
        """Iterate over the direct children in document order."""
        child = self.first_child
        while child is not None:
            yield child
            child = child.next

    def __repr__(self) -> str:
        extra = f" {self.literal!r}" if self.literal else ""
        return f"<{self.type_name}{extra}>"


class LinkNode(Node):
    """A link or image node: adds a destination and an optional title."""

    __slots__ = ("dest", "title")

    def __init__(self, type: int, dest: str, title: str | None) -> None:
        super().__init__(type)
        self.dest = dest
        self.title = title


class Block(Node):
    """A block-level node.

    On top of :class:`Node` it records the data that the block parser and
    the renderer need: heading level, list properties, code-block fence
    data, the accumulated text lines and the "last line blank" flags.
    """

    __slots__ = (
        "open",
        "lines",
        "last_line_blank",
        "checked",
        "start_line",
        "level",
        "ordered",
        "marker",
        "start",
        "tight",
        "marker_offset",
        "padding",
        "fenced",
        "fence_char",
        "fence_len",
        "fence_offset",
        "info",
    )

    def __init__(self, type: int) -> None:
        super().__init__(type)
        self.open = True
        self.lines: list[str] = []
        self.last_line_blank = False
        self.checked = False
        self.start_line = 0
        self.level = 0  # heading level
        self.ordered = False  # list: ordered?
        self.marker = ""  # list: bullet character or ordered delimiter
        self.start = 0  # list: start number
        self.tight = True  # list: tight?
        self.marker_offset = 0  # item: indentation before the marker
        self.padding = 0  # item: marker width plus following spaces
        self.fenced = False  # code block: fenced?
        self.fence_char = ""
        self.fence_len = 0
        self.fence_offset = 0
        self.info = ""  # code block: decoded info string
