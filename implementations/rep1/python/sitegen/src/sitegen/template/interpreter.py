"""Tree-walking interpreter for parsed templates."""

from __future__ import annotations

from . import nodes as n
from .errors import TemplateTypeError, UndefinedError
from .filters import FILTERS
from .parser import Template
from .values import (
    UNDEFINED, Macro, Scope, get_item, is_number, sequence, to_str, truthy,
)

_MISSING = object()


class _Range:
    """The built-in ``range`` callable."""

    __slots__ = ()


RANGE = _Range()


class SuperRef:
    """The value bound to ``super`` inside a block body."""

    __slots__ = ("rendering", "name", "index")

    def __init__(self, rendering, name, index) -> None:
        self.rendering = rendering
        self.name = name
        self.index = index


class Rendering:
    """State of one rendering: the main template or one ``include``."""

    __slots__ = ("scope", "chains", "next_parent")

    def __init__(self, scope: Scope) -> None:
        self.scope = scope
        self.chains: dict[str, list[n.Block]] = {}
        self.next_parent: Template | None = None


def _arith(op: str, a, b):
    if a is UNDEFINED or b is UNDEFINED:
        raise UndefinedError("undefined operand")
    a_num = isinstance(a, (int, float))
    b_num = isinstance(b, (int, float))
    if op == "+":
        if a_num and b_num:
            return a + b
        if type(a) is str and type(b) is str or type(a) is list and type(b) is list:
            return a + b
    elif op == "-":
        if a_num and b_num:
            return a - b
    elif op == "*":
        if a_num and b_num:
            return a * b
        if type(a) is str and isinstance(b, int):
            return a * b
        if isinstance(a, int) and type(b) is str:
            return b * a
    elif op == "/":
        if a_num and b_num:
            if b == 0:
                raise TemplateTypeError("division by zero")
            return a / b
    elif op == "//":
        if a_num and b_num:
            if b == 0:
                raise TemplateTypeError("division by zero")
            return a // b
    elif op == "%":
        if a_num and b_num:
            if b == 0:
                raise TemplateTypeError("modulo by zero")
            return a % b
    elif op == "**":
        if a_num and b_num:
            try:
                result = a**b
            except (ZeroDivisionError, OverflowError):
                raise TemplateTypeError("invalid power") from None
            if isinstance(result, complex):
                raise TemplateTypeError("complex result")
            return result
    raise TemplateTypeError(f"unsupported operand types for {op}")


def _compare(op: str, a, b) -> bool:
    if a is UNDEFINED or b is UNDEFINED:
        raise UndefinedError("undefined operand")
    if op == "==":
        return a == b
    if op == "!=":
        return a != b
    if op == "in" or op == "not in":
        cls = type(b)
        if cls is str:
            if type(a) is not str:
                raise TemplateTypeError("'in <string>' requires a string")
            found = a in b
        elif cls is dict:
            found = type(a) is str and a in b
        elif cls is list:
            found = a in b
        else:
            raise TemplateTypeError("unsupported right operand of 'in'")
        return found if op == "in" else not found
    if (is_number(a) and is_number(b)) or (type(a) is str and type(b) is str):
        if op == "<":
            return a < b
        if op == "<=":
            return a <= b
        if op == ">":
            return a > b
        return a >= b
    raise TemplateTypeError(f"cannot order these values with {op}")


class Interpreter:
    """Executes templates obtained from *loader* (``name -> Template``)."""

    def __init__(self, loader) -> None:
        self.loader = loader
        self._eval = {
            n.Const: self._ev_const,
            n.Name: self._ev_name,
            n.ListLit: self._ev_list,
            n.GetItem: self._ev_getitem,
            n.Call: self._ev_call,
            n.FilterCall: self._ev_filter,
            n.IsDefined: self._ev_is_defined,
            n.Neg: self._ev_neg,
            n.Not: self._ev_not,
            n.BinOp: self._ev_binop,
            n.BoolOp: self._ev_boolop,
            n.Compare: self._ev_compare,
        }

    # -- rendering -----------------------------------------------------------

    def render(self, template: Template, context: dict) -> str:
        out: list[str] = []
        self.render_template(template, Scope(None, dict(context)), out)
        return "".join(out)

    def render_template(self, template: Template, parent_scope: Scope, out: list) -> None:
        scope = Scope(parent_scope)
        rendering = Rendering(scope)
        for name, block in template.blocks.items():
            rendering.chains[name] = [block]
        current: Template | None = template
        while current is not None:
            rendering.next_parent = None
            self.exec_body(current.body, scope, rendering, out, True)
            current = rendering.next_parent

    def render_block(self, rendering: Rendering, name: str, index: int, out: list) -> None:
        block = rendering.chains[name][index]
        scope = Scope(rendering.scope)
        scope.vars["super"] = SuperRef(rendering, name, index + 1)
        self.exec_body(block.body, scope, rendering, out, True)

    # -- statements ------------------------------------------------------------

    def exec_body(self, body: list, scope: Scope, rendering: Rendering, out: list, emit: bool) -> None:
        for node in body:
            cls = node.__class__
            if cls is n.Text:
                if emit:
                    out.append(node.text)
            elif cls is n.Output:
                if emit:
                    out.append(to_str(self._eval[node.expr.__class__](node.expr, scope)))
            elif cls is n.If:
                for condition, branch in node.branches:
                    if truthy(self._eval[condition.__class__](condition, scope)):
                        self.exec_body(branch, scope, rendering, out, emit)
                        break
                else:
                    if node.orelse is not None:
                        self.exec_body(node.orelse, scope, rendering, out, emit)
            elif cls is n.For:
                self._exec_for(node, scope, rendering, out, emit)
            elif cls is n.Set:
                scope.vars[node.name] = self._eval[node.expr.__class__](node.expr, scope)
            elif cls is n.MacroDef:
                scope.vars[node.name] = Macro(node, scope, rendering)
            elif cls is n.Include:
                if emit:
                    name = self._eval[node.expr.__class__](node.expr, scope)
                    self.render_template(self._load(name), scope, out)
            elif cls is n.Block:
                if emit:
                    self.render_block(rendering, node.name, 0, out)
            elif cls is n.Extends:
                parent = self._load(self._eval[node.expr.__class__](node.expr, scope))
                for name, block in parent.blocks.items():
                    rendering.chains.setdefault(name, []).append(block)
                rendering.next_parent = parent
                emit = False

    def _load(self, name) -> Template:
        if name is UNDEFINED:
            raise UndefinedError("undefined template name")
        if type(name) is not str:
            raise TemplateTypeError("template name must be a string")
        return self.loader(name)

    def _exec_for(self, node: n.For, scope: Scope, rendering: Rendering, out: list, emit: bool) -> None:
        items = sequence(self._eval[node.iterable.__class__](node.iterable, scope))
        if not items:
            if node.orelse is not None:
                self.exec_body(node.orelse, scope, rendering, out, emit)
            return
        var = node.var
        body = node.body
        length = len(items)
        last = length - 1
        for index, item in enumerate(items):
            loop = {"index": index + 1, "index0": index, "first": index == 0, "last": index == last, "length": length}
            self.exec_body(body, Scope(scope, {var: item, "loop": loop}), rendering, out, emit)

    # -- expressions -----------------------------------------------------------

    def evaluate(self, node, scope: Scope):
        return self._eval[node.__class__](node, scope)

    def _ev_const(self, node, scope):
        return node.value

    def _ev_name(self, node, scope):
        name = node.name
        while scope is not None:
            value = scope.vars.get(name, _MISSING)
            if value is not _MISSING:
                return value
            scope = scope.parent
        return RANGE if name == "range" else UNDEFINED

    def _ev_list(self, node, scope):
        ev = self._eval
        return [ev[item.__class__](item, scope) for item in node.items]

    def _ev_getitem(self, node, scope):
        ev = self._eval
        obj = ev[node.obj.__class__](node.obj, scope)
        key_node = node.key
        key = ev[key_node.__class__](key_node, scope)
        return get_item(obj, key)

    def _ev_is_defined(self, node, scope):
        value = self._eval[node.value.__class__](node.value, scope)
        return (value is not UNDEFINED) != node.negated

    def _ev_neg(self, node, scope):
        value = self._eval[node.operand.__class__](node.operand, scope)
        if value is UNDEFINED:
            raise UndefinedError("undefined operand")
        if not isinstance(value, (int, float)):
            raise TemplateTypeError("cannot negate a non-number")
        return -value

    def _ev_not(self, node, scope):
        return not truthy(self._eval[node.operand.__class__](node.operand, scope))

    def _ev_binop(self, node, scope):
        ev = self._eval
        left = ev[node.left.__class__](node.left, scope)
        right = ev[node.right.__class__](node.right, scope)
        op = node.op
        if op == "~":
            return to_str(left) + to_str(right)
        return _arith(op, left, right)

    def _ev_boolop(self, node, scope):
        ev = self._eval
        left = ev[node.left.__class__](node.left, scope)
        if truthy(left) == (node.op == "or"):
            return left
        return ev[node.right.__class__](node.right, scope)

    def _ev_compare(self, node, scope):
        ev = self._eval
        left = ev[node.first.__class__](node.first, scope)
        for op, expr in node.rest:
            right = ev[expr.__class__](expr, scope)
            if not _compare(op, left, right):
                return False
            left = right
        return True

    def _ev_filter(self, node, scope):
        ev = self._eval
        value = ev[node.value.__class__](node.value, scope)
        args = [ev[arg.__class__](arg, scope) for arg in node.args]
        func, low, high = FILTERS[node.name]
        if value is UNDEFINED and node.name != "default":
            raise UndefinedError(f"undefined value passed to filter {node.name!r}")
        if not low <= len(args) <= high:
            raise TemplateTypeError(f"wrong number of arguments for filter {node.name!r}")
        return func(value, *args)

    def _ev_call(self, node, scope):
        ev = self._eval
        func = ev[node.func.__class__](node.func, scope)
        args = [ev[arg.__class__](arg, scope) for arg in node.args]
        kwargs = [(name, ev[expr.__class__](expr, scope)) for name, expr in node.kwargs]
        if isinstance(func, Macro):
            return self._call_macro(func, args, kwargs)
        if func is RANGE:
            return self._call_range(args, kwargs)
        if isinstance(func, SuperRef):
            if args or kwargs:
                raise TemplateTypeError("super() takes no arguments")
            chain = func.rendering.chains[func.name]
            if func.index >= len(chain):
                raise UndefinedError("super() has no less-derived block")
            out: list[str] = []
            self.render_block(func.rendering, func.name, func.index, out)
            return "".join(out)
        if func is UNDEFINED:
            raise UndefinedError("call of an undefined value")
        raise TemplateTypeError("value is not callable")

    def _call_macro(self, macro: Macro, args: list, kwargs: list):
        params = macro.node.params
        if len(args) > len(params):
            raise TemplateTypeError("too many arguments for macro")
        scope = Scope(macro.scope)
        bound = scope.vars
        for (name, _), value in zip(params, args):
            bound[name] = value
        names = {name for name, _ in params}
        for name, value in kwargs:
            if name not in names or name in bound:
                raise TemplateTypeError(f"bad keyword argument {name!r}")
            bound[name] = value
        for name, default in params:
            if name not in bound:
                bound[name] = UNDEFINED if default is None else self.evaluate(default, scope)
        out: list[str] = []
        self.exec_body(macro.node.body, scope, macro.rendering, out, True)
        return "".join(out)

    @staticmethod
    def _call_range(args: list, kwargs: list):
        if kwargs:
            raise TemplateTypeError("range() takes no keyword arguments")
        if not 1 <= len(args) <= 3:
            raise TemplateTypeError("range() takes one to three arguments")
        for arg in args:
            if arg is UNDEFINED:
                raise UndefinedError("undefined argument to range()")
            if not isinstance(arg, int):
                raise TemplateTypeError("range() arguments must be integers")
        if len(args) == 3 and args[2] == 0:
            raise TemplateTypeError("range() step must not be zero")
        return list(range(*[int(arg) for arg in args]))
