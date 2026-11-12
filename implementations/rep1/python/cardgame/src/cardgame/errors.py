"""Exception types shared across the package."""


class CardGameError(Exception):
    """Base class for every error raised deliberately by this package."""


class DatabaseError(CardGameError):
    """The card database could not be read, tokenised or validated."""


class SetupError(CardGameError):
    """The setup block of a match file is invalid.

    ``kind`` is the token printed after ``FATAL`` (``bad-setup``,
    ``bad-database`` or ``unknown-card``).
    """

    def __init__(self, kind: str):
        super().__init__(kind)
        self.kind = kind


class MatchEnded(CardGameError):
    """Raised inside the engine to unwind everything once the match is over."""
