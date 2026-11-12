"""Syntax tree node classes.

Nodes are plain data holders; all behaviour lives in the parser (which builds
them) and the interpreter (which walks them).
"""

from __future__ import annotations

from typing import Any, Callable


class Node:
    __slots__ = ()


# --------------------------------------------------------------------------
# Expressions
# --------------------------------------------------------------------------


class Const(Node):
    __slots__ = ("value",)

    def __init__(self, value: Any) -> None:
        self.value = value


class Name(Node):
    __slots__ = ("name",)

    def __init__(self, name: str) -> None:
        self.name = name


class ListLit(Node):
    __slots__ = ("items",)

    def __init__(self, items: list[Node]) -> None:
        self.items = items


class Getitem(Node):
    """``obj.NAME`` or ``obj[key]`` (the same operation)."""

    __slots__ = ("obj", "key")

    def __init__(self, obj: Node, key: Node) -> None:
        self.obj = obj
        self.key = key


class Call(Node):
    __slots__ = ("callee", "args", "kwargs")

    def __init__(self, callee: Node, args: list[Node], kwargs: list[tuple[str, Node]]) -> None:
        self.callee = callee
        self.args = args
        self.kwargs = kwargs


class FilterCall(Node):
    __slots__ = ("value", "name", "args")

    def __init__(self, value: Node, name: str, args: list[Node]) -> None:
        self.value = value
        self.name = name
        self.args = args


class IsDefined(Node):
    __slots__ = ("value", "negated")

    def __init__(self, value: Node, negated: bool) -> None:
        self.value = value
        self.negated = negated


class Neg(Node):
    __slots__ = ("operand",)

    def __init__(self, operand: Node) -> None:
        self.operand = operand


class Not(Node):
    __slots__ = ("operand",)

    def __init__(self, operand: Node) -> None:
        self.operand = operand


class And(Node):
    __slots__ = ("left", "right")

    def __init__(self, left: Node, right: Node) -> None:
        self.left = left
        self.right = right


class Or(Node):
    __slots__ = ("left", "right")

    def __init__(self, left: Node, right: Node) -> None:
        self.left = left
        self.right = right


class BinOp(Node):
    __slots__ = ("op", "fn", "left", "right")

    def __init__(self, op: str, fn: Callable[[Any, Any], Any], left: Node, right: Node) -> None:
        self.op = op
        self.fn = fn
        self.left = left
        self.right = right


class Compare(Node):
    """A comparison chain: ``first op1 e1 op2 e2 ...``."""

    __slots__ = ("first", "rest")

    def __init__(self, first: Node, rest: list[tuple[Callable[[Any, Any], bool], Node]]) -> None:
        self.first = first
        self.rest = rest


# --------------------------------------------------------------------------
# Statements
# --------------------------------------------------------------------------


class Text(Node):
    __slots__ = ("text",)

    def __init__(self, text: str) -> None:
        self.text = text


class Print(Node):
    __slots__ = ("expr",)

    def __init__(self, expr: Node) -> None:
        self.expr = expr


class If(Node):
    __slots__ = ("branches", "orelse")

    def __init__(self, branches: list[tuple[Node, list[Node]]], orelse: list[Node] | None) -> None:
        self.branches = branches
        self.orelse = orelse


class For(Node):
    __slots__ = ("target", "iterable", "body", "orelse")

    def __init__(self, target: str, iterable: Node, body: list[Node], orelse: list[Node] | None) -> None:
        self.target = target
        self.iterable = iterable
        self.body = body
        self.orelse = orelse


class Set(Node):
    __slots__ = ("target", "expr")

    def __init__(self, target: str, expr: Node) -> None:
        self.target = target
        self.expr = expr


class MacroDef(Node):
    __slots__ = ("name", "params", "body")

    def __init__(self, name: str, params: list[tuple[str, Node | None]], body: list[Node]) -> None:
        self.name = name
        self.params = params
        self.body = body


class Include(Node):
    __slots__ = ("expr",)

    def __init__(self, expr: Node) -> None:
        self.expr = expr


class Extends(Node):
    __slots__ = ("expr",)

    def __init__(self, expr: Node) -> None:
        self.expr = expr


class Block(Node):
    __slots__ = ("name", "body")

    def __init__(self, name: str, body: list[Node]) -> None:
        self.name = name
        self.body = body


class Template:
    """A parsed template: its body, static block table and filter names."""

    __slots__ = ("name", "body", "blocks", "filters")

    def __init__(self, name: str, body: list[Node], blocks: dict[str, Block], filters: set[str]) -> None:
        self.name = name
        self.body = body
        self.blocks = blocks
        self.filters = filters
