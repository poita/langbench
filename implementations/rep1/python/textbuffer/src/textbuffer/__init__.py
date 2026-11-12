"""textbuffer: a text buffer with multiple cursors, selections and undo/redo."""

from .buffer import Direction, TextBuffer
from .commands import CommandError, Interpreter, decode_text, parse_input
from .cursor import Cursor, CursorState, normalize
from .document import Document, Position
from .history import History, Replacement, UndoEntry

__all__ = [
    "CommandError",
    "Cursor",
    "CursorState",
    "Direction",
    "Document",
    "History",
    "Interpreter",
    "Position",
    "Replacement",
    "TextBuffer",
    "UndoEntry",
    "decode_text",
    "normalize",
    "parse_input",
]
__version__ = "1.0.0"
