"""Exception hierarchy."""


class DatalogError(Exception):
    """Base class of every error raised by this package."""


class ParseError(DatalogError):
    """The program text is not syntactically well formed."""


class UnsafeRuleError(DatalogError):
    """A rule has a variable that occurs in no positive body atom."""


class StratificationError(DatalogError):
    """A predicate depends negatively on itself (through a cycle)."""
