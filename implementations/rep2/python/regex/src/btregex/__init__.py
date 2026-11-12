"""btregex -- a backtracking regular-expression engine written from scratch.

Perl-style leftmost, greedy, ordered-choice semantics for a small syntax
(literals, ``.``, ``^``, ``$``, classes, ``\\d \\w \\s``, capturing groups,
alternation and ``* + ? {n} {n,} {n,m}`` quantifiers).

>>> import btregex
>>> m = btregex.compile(r"(a|ab)(c|bcd)(d*)").search("abcd")
>>> m.span(), m.groups
((0, 4), ((0, 1), (1, 4), (4, 4)))
"""

from .errors import PatternSyntaxError
from .pattern import Match, Pattern, compile, search

__all__ = ["Match", "Pattern", "PatternSyntaxError", "compile", "search"]
__version__ = "1.0.0"
