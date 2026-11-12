"""Syntax tree of the template language."""

from __future__ import annotations


class Node:
    __slots__ = ()


# -- expressions ----------------------------------------------------------

class Const(Node):
    __slots__ = ("value",)

    def __init__(self, value):
        self.value = value


class Name(Node):
    __slots__ = ("name",)

    def __init__(self, name):
        self.name = name


class ListLit(Node):
    __slots__ = ("items",)

    def __init__(self, items):
        self.items = items


class GetItem(Node):
    """``obj.name`` (with a constant key) or ``obj[expr]``."""

    __slots__ = ("obj", "key")

    def __init__(self, obj, key):
        self.obj = obj
        self.key = key


class Call(Node):
    __slots__ = ("func", "args", "kwargs")

    def __init__(self, func, args, kwargs):
        self.func = func
        self.args = args
        self.kwargs = kwargs  # list of (name, expression)


class FilterCall(Node):
    __slots__ = ("value", "name", "args")

    def __init__(self, value, name, args):
        self.value = value
        self.name = name
        self.args = args


class IsDefined(Node):
    __slots__ = ("value", "negated")

    def __init__(self, value, negated):
        self.value = value
        self.negated = negated


class Neg(Node):
    __slots__ = ("operand",)

    def __init__(self, operand):
        self.operand = operand


class Not(Node):
    __slots__ = ("operand",)

    def __init__(self, operand):
        self.operand = operand


class BinOp(Node):
    __slots__ = ("op", "left", "right")

    def __init__(self, op, left, right):
        self.op = op
        self.left = left
        self.right = right


class BoolOp(Node):
    """Short-circuit ``and`` / ``or``."""

    __slots__ = ("op", "left", "right")

    def __init__(self, op, left, right):
        self.op = op
        self.left = left
        self.right = right


class Compare(Node):
    """A chain ``first op1 e1 op2 e2 ...``."""

    __slots__ = ("first", "rest")

    def __init__(self, first, rest):
        self.first = first
        self.rest = rest  # list of (operator, expression)


# -- statements -------------------------------------------------------------

class Text(Node):
    __slots__ = ("text",)

    def __init__(self, text):
        self.text = text


class Output(Node):
    __slots__ = ("expr",)

    def __init__(self, expr):
        self.expr = expr


class If(Node):
    __slots__ = ("branches", "orelse")

    def __init__(self, branches, orelse):
        self.branches = branches  # list of (condition, body)
        self.orelse = orelse


class For(Node):
    __slots__ = ("var", "iterable", "body", "orelse")

    def __init__(self, var, iterable, body, orelse):
        self.var = var
        self.iterable = iterable
        self.body = body
        self.orelse = orelse


class Set(Node):
    __slots__ = ("name", "expr")

    def __init__(self, name, expr):
        self.name = name
        self.expr = expr


class MacroDef(Node):
    __slots__ = ("name", "params", "body")

    def __init__(self, name, params, body):
        self.name = name
        self.params = params  # list of (name, default expression or None)
        self.body = body


class Include(Node):
    __slots__ = ("expr",)

    def __init__(self, expr):
        self.expr = expr


class Extends(Node):
    __slots__ = ("expr",)

    def __init__(self, expr):
        self.expr = expr


class Block(Node):
    __slots__ = ("name", "body")

    def __init__(self, name, body):
        self.name = name
        self.body = body
