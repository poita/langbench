"""Tree-walking interpreter.

The interpreter executes parsed templates against a chain of lexical
:class:`Scope` objects.  Output is appended to a list of string chunks; a
``None`` output means "executing, but producing nothing" (the part of a child
template that follows its ``extends`` tag).
"""

from __future__ import annotations

from typing import Any, Callable

from . import nodes as n
from . import operators
from .errors import (
    TemplateNotFoundError,
    TemplateTypeError,
    UndefinedValueError,
)
from .filters import ACCEPTS_UNDEFINED, FILTERS
from .values import (
    UNDEFINED,
    Macro,
    RangeFunction,
    SuperFunction,
    sequence_view,
    to_str,
    truthy,
)

_MISSING = object()
Output = list[str] | None


class Scope:
    """A mapping of names to values plus a parent scope (O(1) to create)."""

    __slots__ = ("vars", "parent")

    def __init__(self, parent: Scope | None = None, variables: dict[str, Any] | None = None) -> None:
        self.vars: dict[str, Any] = {} if variables is None else variables
        self.parent = parent

    def lookup(self, name: str) -> Any:
        scope: Scope | None = self
        while scope is not None:
            value = scope.vars.get(name, _MISSING)
            if value is not _MISSING:
                return value
            scope = scope.parent
        return UNDEFINED


class Rendering:
    """State of one rendering (the main template, or one ``include``)."""

    __slots__ = ("scope", "chains")

    def __init__(self, scope: Scope, chains: dict[str, list[n.Block]]) -> None:
        #: The template scope shared by the template and its ancestors.
        self.scope = scope
        #: Per block name, bodies from most to least derived.
        self.chains = chains


class Interpreter:
    """Executes templates; ``loader`` maps a name to a loaded template.

    ``loader`` raises :class:`~jtemplate.errors.TemplateNotFoundError` for an
    unknown name and the syntax/filter errors for a broken template.
    """

    def __init__(self, loader: Callable[[str], n.Template]) -> None:
        self._load = loader
        self._exec_table: dict[type, Callable[..., None]] = {
            n.Text: self._exec_text,
            n.Print: self._exec_print,
            n.If: self._exec_if,
            n.For: self._exec_for,
            n.Set: self._exec_set,
            n.MacroDef: self._exec_macro,
            n.Include: self._exec_include,
            n.Block: self._exec_block,
        }
        self._eval_table: dict[type, Callable[[Any, Scope], Any]] = {
            n.Const: lambda node, scope: node.value,
            n.Name: lambda node, scope: scope.lookup(node.name),
            n.ListLit: self._eval_list,
            n.Getitem: self._eval_getitem,
            n.Call: self._eval_call,
            n.FilterCall: self._eval_filter,
            n.IsDefined: self._eval_is_defined,
            n.Neg: self._eval_neg,
            n.Not: self._eval_not,
            n.And: self._eval_and,
            n.Or: self._eval_or,
            n.BinOp: self._eval_binop,
            n.Compare: self._eval_compare,
        }
        base = Scope(None, {"range": RangeFunction()})
        self._base = base

    # ------------------------------------------------------------------
    # Entry point
    # ------------------------------------------------------------------

    def render(self, template: n.Template, context: dict[str, Any]) -> str:
        """Render ``template`` with ``context`` as the root scope."""
        root = Scope(self._base, dict(context))
        out: list[str] = []
        self._run_template(template, Scope(root), out)
        return "".join(out)

    def _run_template(self, template: n.Template, scope: Scope, out: list[str]) -> None:
        """Run a template and its ``extends`` chain in template scope ``scope``."""
        rendering = Rendering(scope, {name: [block] for name, block in template.blocks.items()})
        while True:
            current: Output = out
            parent: n.Template | None = None
            for node in template.body:
                if type(node) is n.Extends:
                    parent = self._load_named(node.expr, scope)
                    for name, block in parent.blocks.items():
                        rendering.chains.setdefault(name, []).append(block)
                    current = None
                else:
                    self._exec_table[type(node)](node, rendering, scope, current)
            if parent is None:
                return
            template = parent

    def _load_named(self, expr: n.Node, scope: Scope) -> n.Template:
        name = self._eval(expr, scope)
        if name is UNDEFINED:
            raise UndefinedValueError("template name is undefined")
        if not isinstance(name, str):
            raise TemplateTypeError("template name must be a string")
        return self._load(name)

    # ------------------------------------------------------------------
    # Statements
    # ------------------------------------------------------------------

    def _exec_nodes(self, body: list[n.Node], rendering: Rendering, scope: Scope, out: Output) -> None:
        table = self._exec_table
        for node in body:
            table[type(node)](node, rendering, scope, out)

    def _exec_text(self, node: n.Text, rendering: Rendering, scope: Scope, out: Output) -> None:
        if out is not None:
            out.append(node.text)

    def _exec_print(self, node: n.Print, rendering: Rendering, scope: Scope, out: Output) -> None:
        if out is not None:
            out.append(to_str(self._eval(node.expr, scope)))

    def _exec_if(self, node: n.If, rendering: Rendering, scope: Scope, out: Output) -> None:
        for cond, body in node.branches:
            if truthy(self._eval(cond, scope)):
                self._exec_nodes(body, rendering, scope, out)
                return
        if node.orelse is not None:
            self._exec_nodes(node.orelse, rendering, scope, out)

    def _exec_for(self, node: n.For, rendering: Rendering, scope: Scope, out: Output) -> None:
        items = sequence_view(self._eval(node.iterable, scope))
        count = len(items)
        if count == 0:
            if node.orelse is not None:
                self._exec_nodes(node.orelse, rendering, scope, out)
            return
        target = node.target
        body = node.body
        table = self._exec_table
        last = count - 1
        for index, item in enumerate(items):
            loop = {
                "index": index + 1,
                "index0": index,
                "first": index == 0,
                "last": index == last,
                "length": count,
            }
            inner = Scope(scope, {target: item, "loop": loop})
            for child in body:
                table[type(child)](child, rendering, inner, out)

    def _exec_set(self, node: n.Set, rendering: Rendering, scope: Scope, out: Output) -> None:
        scope.vars[node.target] = self._eval(node.expr, scope)

    def _exec_macro(self, node: n.MacroDef, rendering: Rendering, scope: Scope, out: Output) -> None:
        scope.vars[node.name] = Macro(node, scope, rendering)

    def _exec_include(self, node: n.Include, rendering: Rendering, scope: Scope, out: Output) -> None:
        if out is None:
            return
        template = self._load_named(node.expr, scope)
        self._run_template(template, Scope(scope), out)

    def _exec_block(self, node: n.Block, rendering: Rendering, scope: Scope, out: Output) -> None:
        if out is None:
            return
        chain = rendering.chains.get(node.name)
        if chain is None:
            chain = rendering.chains[node.name] = [node]
        self._render_block(rendering, chain, 0, out)

    def _render_block(self, rendering: Rendering, chain: list[n.Block], index: int, out: list[str]) -> None:
        def render_super() -> str:
            if index + 1 >= len(chain):
                raise UndefinedValueError("super() without a parent block")
            buffer: list[str] = []
            self._render_block(rendering, chain, index + 1, buffer)
            return "".join(buffer)

        scope = Scope(rendering.scope, {"super": SuperFunction(render_super)})
        self._exec_nodes(chain[index].body, rendering, scope, out)

    # ------------------------------------------------------------------
    # Expressions
    # ------------------------------------------------------------------

    def _eval(self, node: n.Node, scope: Scope) -> Any:
        return self._eval_table[type(node)](node, scope)

    def _eval_list(self, node: n.ListLit, scope: Scope) -> list:
        ev = self._eval
        return [ev(item, scope) for item in node.items]

    def _eval_getitem(self, node: n.Getitem, scope: Scope) -> Any:
        obj = self._eval(node.obj, scope)
        key = self._eval(node.key, scope)
        if obj is UNDEFINED or key is UNDEFINED:
            raise UndefinedValueError("subscript of or with undefined")
        if isinstance(obj, dict):
            if isinstance(key, str):
                return obj.get(key, UNDEFINED)
        elif isinstance(obj, (list, str)):
            if isinstance(key, int) and -len(obj) <= key < len(obj):
                return obj[key]
        return UNDEFINED

    def _eval_is_defined(self, node: n.IsDefined, scope: Scope) -> bool:
        defined = self._eval(node.value, scope) is not UNDEFINED
        return defined != node.negated

    def _eval_neg(self, node: n.Neg, scope: Scope) -> Any:
        return operators.neg(self._eval(node.operand, scope))

    def _eval_not(self, node: n.Not, scope: Scope) -> bool:
        return not truthy(self._eval(node.operand, scope))

    def _eval_and(self, node: n.And, scope: Scope) -> Any:
        left = self._eval(node.left, scope)
        if not truthy(left):
            return left
        return self._eval(node.right, scope)

    def _eval_or(self, node: n.Or, scope: Scope) -> Any:
        left = self._eval(node.left, scope)
        if truthy(left):
            return left
        return self._eval(node.right, scope)

    def _eval_binop(self, node: n.BinOp, scope: Scope) -> Any:
        left = self._eval(node.left, scope)
        right = self._eval(node.right, scope)
        return node.fn(left, right)

    def _eval_compare(self, node: n.Compare, scope: Scope) -> bool:
        left = self._eval(node.first, scope)
        for fn, operand in node.rest:
            right = self._eval(operand, scope)
            if not fn(left, right):
                return False
            left = right
        return True

    def _eval_filter(self, node: n.FilterCall, scope: Scope) -> Any:
        value = self._eval(node.value, scope)
        args = [self._eval(arg, scope) for arg in node.args]
        name = node.name
        if value is UNDEFINED and name not in ACCEPTS_UNDEFINED:
            raise UndefinedValueError(f"undefined value passed to filter {name!r}")
        spec = FILTERS[name]
        if not spec.min_args <= len(args) <= spec.max_args:
            raise TemplateTypeError(f"wrong number of arguments for filter {name!r}")
        for arg in args:
            if arg is UNDEFINED and name != "default":
                raise UndefinedValueError(f"undefined argument to filter {name!r}")
        return spec.func(value, *args)

    # -- calls ---------------------------------------------------------

    def _eval_call(self, node: n.Call, scope: Scope) -> Any:
        callee = self._eval(node.callee, scope)
        ev = self._eval
        args = [ev(arg, scope) for arg in node.args]
        kwargs = [(key, ev(value, scope)) for key, value in node.kwargs]
        if isinstance(callee, Macro):
            return self._call_macro(callee, args, kwargs)
        if isinstance(callee, RangeFunction):
            return self._call_range(args, kwargs)
        if isinstance(callee, SuperFunction):
            if args or kwargs:
                raise TemplateTypeError("super() takes no arguments")
            return callee.render()
        if callee is UNDEFINED:
            raise UndefinedValueError("calling undefined")
        raise TemplateTypeError("value is not callable")

    def _call_range(self, args: list[Any], kwargs: list[tuple[str, Any]]) -> list[int]:
        if kwargs:
            raise TemplateTypeError("range takes no keyword arguments")
        if not 1 <= len(args) <= 3:
            raise TemplateTypeError("range takes 1 to 3 arguments")
        for arg in args:
            if arg is UNDEFINED:
                raise UndefinedValueError("undefined argument to range")
            if not isinstance(arg, int):
                raise TemplateTypeError("range arguments must be integers")
        ints = [int(arg) for arg in args]
        if len(ints) == 3 and ints[2] == 0:
            raise TemplateTypeError("range step must not be zero")
        return list(range(*ints))

    def _call_macro(self, macro: Macro, args: list[Any], kwargs: list[tuple[str, Any]]) -> str:
        node = macro.node
        params = node.params
        if len(args) > len(params):
            raise TemplateTypeError(f"macro {node.name!r} got too many arguments")
        scope = Scope(macro.scope)
        bound = scope.vars
        for (pname, _), value in zip(params, args):
            bound[pname] = value
        if kwargs:
            names = {pname for pname, _ in params}
            for key, value in kwargs:
                if key not in names or key in bound:
                    raise TemplateTypeError(f"bad keyword argument {key!r} for macro {node.name!r}")
                bound[key] = value
        for pname, default in params:
            if pname not in bound:
                bound[pname] = UNDEFINED if default is None else self._eval(default, scope)
        buffer: list[str] = []
        self._exec_nodes(node.body, macro.rendering, scope, buffer)
        return "".join(buffer)
