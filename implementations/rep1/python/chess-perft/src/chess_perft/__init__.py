"""chess-perft: a bitboard legal move generator with perft and divide.

Quick start::

    >>> from chess_perft import START_FEN, Position, perft
    >>> perft(Position.from_fen(START_FEN), 3)
    8902
"""

from .constants import BLACK, WHITE
from .movegen import count_legal_moves, generate_legal_moves
from .moves import move_to_uci
from .perft import divide, perft
from .position import START_FEN, FenError, Position

__all__ = [
    "BLACK", "WHITE", "START_FEN", "FenError", "Position", "count_legal_moves",
    "divide", "generate_legal_moves", "move_to_uci", "perft",
]
