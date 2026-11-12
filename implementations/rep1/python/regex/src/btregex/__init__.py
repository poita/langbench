"""btregex: a small backtracking regular-expression engine.

Perl-style semantics: the leftmost match wins, quantifiers are greedy and
alternation is ordered.  Example::

    >>> import btregex
    >>> m = btregex.compile(r"(a|ab)(c|bcd)(d*)").search("abcd")
    >>> m.span(), m.spans
    ((0, 4), ((0, 1), (1, 4), (4, 4)))
"""

from .errors import PatternSyntaxError
from .pattern import Match, Pattern, compile

__all__ = ["Match", "Pattern", "PatternSyntaxError", "compile"]
__version__ = "1.0.0"
