"""KBL abstract syntax tree nodes."""


class Node(object):
    __slots__ = ()


class EInt(Node):
    __slots__ = ("value",)

    def __init__(self, value):
        self.value = value


class EBool(Node):
    __slots__ = ("value",)

    def __init__(self, value):
        self.value = value


class EStr(Node):
    """A double- or single-quoted literal: a list of ``('lit', bytes)`` and
    ``('expr', node)`` parts."""
    __slots__ = ("parts",)

    def __init__(self, parts):
        self.parts = parts


class EVar(Node):
    __slots__ = ("name",)

    def __init__(self, name):
        self.name = name


class EList(Node):
    __slots__ = ("items",)

    def __init__(self, items):
        self.items = items


class ECall(Node):
    __slots__ = ("name", "args")

    def __init__(self, name, args):
        self.name = name
        self.args = args


class EIndex(Node):
    __slots__ = ("target", "index")

    def __init__(self, target, index):
        self.target = target
        self.index = index


class EUnary(Node):
    __slots__ = ("op", "operand")

    def __init__(self, op, operand):
        self.op = op
        self.operand = operand


class EBinary(Node):
    __slots__ = ("op", "left", "right")

    def __init__(self, op, left, right):
        self.op = op
        self.left = left
        self.right = right


class SLet(Node):
    __slots__ = ("name", "expr")

    def __init__(self, name, expr):
        self.name = name
        self.expr = expr


class SSet(Node):
    __slots__ = ("name", "expr")

    def __init__(self, name, expr):
        self.name = name
        self.expr = expr


class SInclude(Node):
    __slots__ = ("expr",)

    def __init__(self, expr):
        self.expr = expr


class SAbort(Node):
    __slots__ = ("expr",)

    def __init__(self, expr):
        self.expr = expr


class SDefault(Node):
    __slots__ = ("expr",)

    def __init__(self, expr):
        self.expr = expr


class SPhony(Node):
    __slots__ = ("name", "expr")

    def __init__(self, name, expr):
        self.name = name
        self.expr = expr


class SUse(Node):
    """``args`` is a list of ``(keyword_or_None, expr)`` pairs."""
    __slots__ = ("name", "args")

    def __init__(self, name, args):
        self.name = name
        self.args = args


class SWhen(Node):
    """``branches`` is a list of ``(condition_or_None, body)`` pairs; a
    ``None`` condition is the ``otherwise`` branch."""
    __slots__ = ("branches",)

    def __init__(self, branches):
        self.branches = branches


class SEach(Node):
    __slots__ = ("ivar", "var", "expr", "body")

    def __init__(self, ivar, var, expr, body):
        self.ivar = ivar
        self.var = var
        self.expr = expr
        self.body = body


class SRule(Node):
    """``params`` is a list of ``(name, default_expr_or_None)`` pairs."""
    __slots__ = ("name", "params", "body")

    def __init__(self, name, params, body):
        self.name = name
        self.params = params
        self.body = body


class SStep(Node):
    """``fields`` is a list of ``('out'|'in'|'after'|'cost'|'depfile', expr)``
    tuples and one ``('cmd', name, args)`` tuple."""
    __slots__ = ("fields",)

    def __init__(self, fields):
        self.fields = fields
