"""The text buffer: document + cursors + history, with the editing commands."""

from __future__ import annotations

from collections.abc import Iterable
from enum import StrEnum

from .cursor import Cursor, CursorState, normalize
from .document import Document, Position, advance
from .history import History, Replacement, UndoEntry


class Direction(StrEnum):
    """Cursor movement directions."""

    LEFT = "left"
    RIGHT = "right"
    UP = "up"
    DOWN = "down"
    HOME = "home"
    END = "end"


class TextBuffer:
    """A text document with multiple cursors and undo/redo.

    Every public method is one editor command. Edit commands (:meth:`insert`,
    :meth:`delete`, :meth:`delete_forward`) apply to every cursor and form a
    single undo step. Cursors are kept normalized (sorted, colliding cursors
    merged) after every command; :attr:`cursors` lists them in cursor order.
    """

    def __init__(self, text: str = "") -> None:
        self._init(Document.from_text(text))

    @classmethod
    def from_lines(cls, lines: Iterable[str]) -> TextBuffer:
        """Create a buffer from lines; no lines means one empty line."""
        buf = cls.__new__(cls)
        buf._init(Document(lines))
        return buf

    def _init(self, doc: Document) -> None:
        self._doc = doc
        self._cursors: list[Cursor] = [Cursor((0, 0), primary=True)]
        self._history = History()

    # -- inspection ------------------------------------------------------

    @property
    def document(self) -> Document:
        return self._doc

    @property
    def text(self) -> str:
        return self._doc.text

    @property
    def lines(self) -> tuple[str, ...]:
        return self._doc.lines

    @property
    def cursors(self) -> tuple[Cursor, ...]:
        """The cursors in cursor order."""
        return tuple(self._cursors)

    @property
    def can_undo(self) -> bool:
        return bool(self._history.undo_stack)

    @property
    def can_redo(self) -> bool:
        return bool(self._history.redo_stack)

    def render(self) -> str:
        """The document, one ``cursor <line> <col>`` row per cursor, then ``--``."""
        rows = [self._doc.text, "\n"]
        rows.extend(f"cursor {c.head[0]} {c.head[1]}\n" for c in self._cursors)
        rows.append("--\n")
        return "".join(rows)

    # -- editing ---------------------------------------------------------

    def insert(self, text: str) -> None:
        """Insert *text* (may contain ``\\n``) at every cursor, replacing selections."""
        self._edit(text, 0)

    def delete(self) -> None:
        """Backspace: delete each selection, or the character before each cursor."""
        self._edit("", -1)

    def delete_forward(self) -> None:
        """Delete each selection, or the character after each cursor."""
        self._edit("", 1)

    def _edit(self, text: str, direction: int) -> None:
        """Apply one replacement per cursor, in cursor order.

        Cursors still to be visited are expressed in the coordinates of the
        document *before the command*. They are mapped to the current document
        in O(1) through the composed effect of all earlier replacements, which
        is fully described by one anchor pair: the original end position of
        the last replacement (``eo``) and where that end now is (``nw``).
        """
        doc = self._doc
        reps: list[Replacement] = []
        out: list[Cursor] = []
        mapped = False
        eo_line = eo_col = nw_line = nw_col = 0

        for cur in self._cursors:
            head = cur.head
            if mapped:
                # Map through the composed shift (positions are >= eo).
                hl, hc = head
                head = (nw_line, nw_col + hc - eo_col) if hl == eo_line else (hl + nw_line - eo_line, hc)
                if cur.anchor is not None:
                    al, ac = cur.anchor
                    anchor = (nw_line, nw_col + ac - eo_col) if al == eo_line else (al + nw_line - eo_line, ac)
                else:
                    anchor = None
            else:
                anchor = cur.anchor

            if anchor is not None:
                # Range: both ends mapped; original end is the cursor's end.
                if anchor < head:
                    start, end = anchor, head
                else:
                    start, end = head, anchor
                orig_end = cur.end
            else:
                start = end = head
                orig_end = cur.head
                if direction < 0:
                    if head == (0, 0):
                        out.append(Cursor(head, None, cur.primary))
                        continue
                    line, col = head
                    start = (line, col - 1) if col > 0 else (line - 1, doc.line_length(line - 1))
                elif direction > 0:
                    if head == doc.end:
                        out.append(Cursor(head, None, cur.primary))
                        continue
                    line, col = head
                    if col < doc.line_length(line):
                        end = (line, col + 1)
                        orig_end = (orig_end[0], orig_end[1] + 1)
                    else:
                        end = (line + 1, 0)
                        orig_end = (orig_end[0] + 1, 0)

            removed, new_end = doc.replace(start, end, text)
            if removed or text:
                reps.append(Replacement(start, removed, text))
                eo_line, eo_col = orig_end
                nw_line, nw_col = new_end
                mapped = True
            out.append(Cursor(new_end, None, cur.primary))

        before = tuple(c.state for c in self._cursors)
        self._cursors = normalize(out)
        if reps:
            after = tuple(c.state for c in self._cursors)
            self._history.record(UndoEntry(before, after, tuple(reps)))

    # -- movement --------------------------------------------------------

    def move(self, direction: Direction | str, select: bool = False) -> None:
        """Move every cursor; with *select*, extend or start selections."""
        direction = Direction(direction)
        doc = self._doc
        last_line = doc.line_count - 1
        out: list[Cursor] = []
        vertical = direction is Direction.UP or direction is Direction.DOWN

        for cur in self._cursors:
            line, col = cur.head
            goal = None
            anchor = cur.anchor
            if not select and anchor is not None and direction in (Direction.LEFT, Direction.RIGHT):
                pos = cur.start if direction is Direction.LEFT else cur.end
                out.append(Cursor(pos, None, cur.primary))
                continue
            if select:
                if anchor is None:
                    anchor = cur.head
            else:
                anchor = None

            if direction is Direction.LEFT:
                if col > 0:
                    head = (line, col - 1)
                elif line > 0:
                    head = (line - 1, doc.line_length(line - 1))
                else:
                    head = (line, col)
            elif direction is Direction.RIGHT:
                if col < doc.line_length(line):
                    head = (line, col + 1)
                elif line < last_line:
                    head = (line + 1, 0)
                else:
                    head = (line, col)
            elif direction is Direction.HOME:
                head = (line, 0)
            elif direction is Direction.END:
                head = (line, doc.line_length(line))
            elif direction is Direction.UP:
                if line == 0:
                    head = (0, 0)
                    goal = 0
                else:
                    head = (line - 1, min(cur.goal, doc.line_length(line - 1)))
                    goal = cur.goal
            else:  # DOWN
                if line == last_line:
                    head = (line, doc.line_length(line))
                    goal = head[1]
                else:
                    head = (line + 1, min(cur.goal, doc.line_length(line + 1)))
                    goal = cur.goal
            out.append(Cursor(head, anchor, cur.primary, goal))

        self._cursors = normalize(out)
        if not vertical:
            self._reset_goals()

    # -- cursor management -----------------------------------------------

    def goto(self, line: int, col: int) -> None:
        """Replace all cursors by one primary cursor at the clamped position."""
        self._cursors = [Cursor(self._doc.clamp(line, col), None, True)]

    def add_cursor(self, line: int, col: int) -> None:
        """Add a non-primary cursor at the clamped position (merging collisions)."""
        self._reset_goals()
        self._cursors.append(Cursor(self._doc.clamp(line, col), None, False))
        self._cursors = normalize(self._cursors)

    def clear_cursors(self) -> None:
        """Remove every cursor except the primary one."""
        self._cursors = [c for c in self._cursors if c.primary]
        self._reset_goals()

    def _reset_goals(self) -> None:
        self._cursors = [Cursor(c.head, c.anchor, c.primary) for c in self._cursors]

    # -- history ---------------------------------------------------------

    def undo(self) -> None:
        """Revert the most recent edit command, if any."""
        stack = self._history.undo_stack
        if stack:
            entry = stack.pop()
            doc = self._doc
            for start, removed, inserted in reversed(entry.replacements):
                doc.replace(start, advance(start, inserted), removed)
            self._history.redo_stack.append(entry)
            self._restore(entry.before)
        else:
            self._reset_goals()

    def redo(self) -> None:
        """Re-apply the most recently undone edit command, if any."""
        stack = self._history.redo_stack
        if stack:
            entry = stack.pop()
            doc = self._doc
            for start, removed, inserted in entry.replacements:
                doc.replace(start, advance(start, removed), inserted)
            self._history.undo_stack.append(entry)
            self._restore(entry.after)
        else:
            self._reset_goals()

    def _restore(self, states: Iterable[CursorState]) -> None:
        self._cursors = [Cursor(s.head, s.anchor, s.primary) for s in states]
