"""Spiremark: a deterministic rules engine for a two-player duelling-card game.

Public API::

    from cardgame import run_match, load_database, Game
"""

from .database import Database, load_database, parse_database
from .engine import Game
from .errors import CardGameError, DatabaseError, SetupError
from .runner import run_match

__all__ = ["run_match", "load_database", "parse_database", "Database", "Game",
           "CardGameError", "DatabaseError", "SetupError"]
__version__ = "1.0.0"
