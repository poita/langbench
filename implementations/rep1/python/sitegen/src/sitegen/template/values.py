"""Runtime values of the template language and their conversions.

Templates work on plain Python values: ``str``, ``int``, ``float``,
``bool``, ``None``, ``list`` and ``dict`` (insertion ordered), plus the
:data:`UNDEFINED` marker and :class:`Macro` objects.
"""

from __future__ import annotations

from .errors import TemplateTypeError, UndefinedError

#: The six characters the template language treats as whitespace.
WHITESPACE = " \t\n\r\x0c\x0b"


class _Undefined:
    """The type of :data:`UNDEFINED`."""

    __slots__ = ()

    def __repr__(self) -> str:
        return "UNDEFINED"

    def __bool__(self) -> bool:  # pragma: no cover - guards accidental use
        raise UndefinedError("truth value of an undefined value")


UNDEFINED = _Undefined()


class Macro:
    """A macro defined by ``{% macro %}``; created by the interpreter."""

    __slots__ = ("node", "scope", "rendering")

    def __init__(self, node, scope, rendering) -> None:
        self.node = node
        self.scope = scope
        self.rendering = rendering


class Scope:
    """A mapping of names to values with a parent scope."""

    __slots__ = ("vars", "parent")

    def __init__(self, parent: Scope | None = None, variables: dict | None = None) -> None:
        self.vars = {} if variables is None else variables
        self.parent = parent


def to_str(value) -> str:
    """The string form of *value*, as used when printing."""
    cls = type(value)
    if cls is str:
        return value
    if cls is int:
        return str(value)
    if cls is bool:
        return "True" if value else "False"
    if cls is float:
        return repr(value)
    if value is None:
        return "None"
    if cls is list:
        return "[" + ", ".join([to_repr(item) for item in value]) + "]"
    if cls is dict:
        return "{" + ", ".join([f"{to_repr(k)}: {to_repr(v)}" for k, v in value.items()]) + "}"
    if value is UNDEFINED:
        raise UndefinedError("cannot print an undefined value")
    if isinstance(value, Macro):
        return f"<macro {value.node.name}>"
    return str(value)


def to_repr(value) -> str:
    """The representation of *value* inside a printed list or dict."""
    if type(value) is str:
        quote = '"' if "'" in value and '"' not in value else "'"
        out = value.replace("\\", "\\\\").replace("\n", "\\n").replace("\r", "\\r").replace("\t", "\\t")
        if quote == "'":
            out = out.replace("'", "\\'")
        return quote + out + quote
    return to_str(value)


def is_number(value) -> bool:
    """True for integers, floats and booleans."""
    return isinstance(value, (int, float))


def truthy(value) -> bool:
    """Truthiness of *value*; testing the undefined value is an error."""
    if value is UNDEFINED:
        raise UndefinedError("truth value of an undefined value")
    return bool(value)


def sequence(value) -> list:
    """The sequence view of *value* (list, dict keys or string characters)."""
    cls = type(value)
    if cls is list:
        return value
    if cls is dict or cls is str:
        return list(value)
    if value is UNDEFINED:
        raise UndefinedError("an undefined value is not iterable")
    raise TemplateTypeError(f"{cls.__name__} is not a sequence")


def get_item(obj, key):
    """``obj.key`` / ``obj[key]``: member, element, or ``UNDEFINED``."""
    if obj is UNDEFINED or key is UNDEFINED:
        raise UndefinedError("attribute or subscript access involving an undefined value")
    if type(obj) is dict:
        if type(key) is str:
            return obj.get(key, UNDEFINED)
        return UNDEFINED
    if (type(obj) is list or type(obj) is str) and isinstance(key, int):
        index = int(key)
        if -len(obj) <= index < len(obj):
            return obj[index]
    return UNDEFINED
