"""rrule -- recurrence rule (RFC 5545 ``RRULE`` subset) expansion.

Occurrence semantics follow python-dateutil's ``rrule``.  Everything,
including the calendar arithmetic, is implemented with the standard library's
basic types only.

>>> from rrule import DateTime, Rule, occurrences
>>> rule = Rule.parse("FREQ=MONTHLY;BYDAY=-1FR;COUNT=3")
>>> [str(o) for o in occurrences(DateTime(1997, 9, 2, 9), rule)]
['19970926T090000', '19971031T090000', '19971128T090000']
"""

from .expand import occurrences
from .rule import DateTime, Line, Rule, RuleError, parse_line

__all__ = ["DateTime", "Line", "Rule", "RuleError", "occurrences", "parse_line"]
__version__ = "0.1.0"
