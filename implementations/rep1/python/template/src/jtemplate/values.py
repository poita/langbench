"""Runtime values and the conversions shared by operators, filters and the
interpreter.

Template values are represented by native Python objects: ``int``, ``float``,
``bool``, ``None``, ``str``, ``list`` and ``dict`` (insertion ordered).  Three
extra kinds exist: the :data:`UNDEFINED` singleton, :class:`Macro`, and the
internal callables :class:`RangeFunction` and :class:`SuperFunction`.
"""

from __future__ import annotations

from typing import Any

from .errors import TemplateTypeError, UndefinedValueError

#: The six whitespace characters recognised by the template language.
WHITESPACE = " \t\n\r\f\v"


class _Undefined:
    """Type of the :data:`UNDEFINED` singleton."""

    __slots__ = ()

    def __repr__(self) -> str:
        return "UNDEFINED"


#: The undefined value (unknown names, misses, empty ``first``...).
UNDEFINED: Any = _Undefined()


class Macro:
    """A macro defined by a ``{% macro %}`` tag.

    ``node`` is the :class:`~jtemplate.nodes.MacroDef`, ``scope`` the scope in
    which the tag executed and ``rendering`` the rendering it belongs to.
    """

    __slots__ = ("node", "scope", "rendering")

    def __init__(self, node: Any, scope: Any, rendering: Any) -> None:
        self.node = node
        self.scope = scope
        self.rendering = rendering

    def __repr__(self) -> str:
        return f"<macro {self.node.name}>"


class RangeFunction:
    """The built-in ``range`` callable."""

    __slots__ = ()

    def __repr__(self) -> str:
        return "<range>"


class SuperFunction:
    """The ``super`` callable bound inside a block body."""

    __slots__ = ("render",)

    def __init__(self, render: Any) -> None:
        #: Zero-argument function returning the rendered parent block.
        self.render = render

    def __repr__(self) -> str:
        return "<super>"


def is_number(value: Any) -> bool:
    """True for integers, floats and booleans."""
    return isinstance(value, (int, float))


def check_defined(value: Any) -> Any:
    """Return ``value`` unchanged, or raise if it is the undefined value."""
    if value is UNDEFINED:
        raise UndefinedValueError("undefined value used")
    return value


def truthy(value: Any) -> bool:
    """Truthiness of a value; testing the undefined value is an error."""
    if value is UNDEFINED:
        raise UndefinedValueError("truth value of undefined")
    return bool(value)


def sequence_view(value: Any) -> list:
    """The sequence view of ``value`` (list, dict keys or string characters).

    Lists are returned as-is (never copied); anything else is a type error.
    """
    if isinstance(value, list):
        return value
    if isinstance(value, dict):
        return list(value)
    if isinstance(value, str):
        return list(value)
    if value is UNDEFINED:
        raise UndefinedValueError("iterating undefined")
    raise TemplateTypeError(f"{type_name(value)} is not a sequence")


def type_name(value: Any) -> str:
    """A human-readable kind name used in error messages."""
    if value is UNDEFINED:
        return "undefined"
    if value is None:
        return "none"
    if isinstance(value, bool):
        return "boolean"
    if isinstance(value, int):
        return "integer"
    if isinstance(value, float):
        return "float"
    if isinstance(value, str):
        return "string"
    if isinstance(value, list):
        return "list"
    if isinstance(value, dict):
        return "dict"
    return "callable"


def to_str(value: Any) -> str:
    """Convert a value to its printed form (raises for undefined)."""
    if isinstance(value, str):
        return value
    if value is True:
        return "True"
    if value is False:
        return "False"
    if value is None:
        return "None"
    if isinstance(value, (int, float)):
        # Python's float repr is the shortest round-tripping digit string and
        # uses exactly the layout the language specifies.
        return repr(value)
    if isinstance(value, (list, dict)):
        parts: list[str] = []
        _repr_into(value, parts)
        return "".join(parts)
    if value is UNDEFINED:
        raise UndefinedValueError("printing undefined")
    return repr(value)


def to_repr(value: Any) -> str:
    """The repr of a value: like :func:`to_str` but strings are quoted."""
    if isinstance(value, str):
        return _quote(value)
    return to_str(value)


def _quote(text: str) -> str:
    quote = '"' if ("'" in text and '"' not in text) else "'"
    body = (
        text.replace("\\", "\\\\")
        .replace("\n", "\\n")
        .replace("\r", "\\r")
        .replace("\t", "\\t")
    )
    if quote == "'":
        body = body.replace("'", "\\'")
    return quote + body + quote


def _repr_into(value: Any, parts: list[str]) -> None:
    if isinstance(value, list):
        parts.append("[")
        first = True
        for item in value:
            if not first:
                parts.append(", ")
            first = False
            _repr_into(item, parts)
        parts.append("]")
    elif isinstance(value, dict):
        parts.append("{")
        first = True
        for key, item in value.items():
            if not first:
                parts.append(", ")
            first = False
            parts.append(_quote(key))
            parts.append(": ")
            _repr_into(item, parts)
        parts.append("}")
    else:
        parts.append(to_repr(value))
