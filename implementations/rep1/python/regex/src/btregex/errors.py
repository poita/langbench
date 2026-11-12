"""Exceptions raised by the engine."""


class PatternSyntaxError(ValueError):
    """Raised when a pattern is not valid in the supported syntax."""

    def __init__(self, message: str, pattern: str, position: int) -> None:
        super().__init__(f"{message} at position {position} in {pattern!r}")
        self.message = message
        self.pattern = pattern
        self.position = position
