"""Tree-walking interpreter for KBL.

Evaluating the build files produces an :class:`Evaluation`: the ordered list of
steps, the phony table and the default target list.  Scopes form a chain of
mutable dictionaries; rules capture the scope they were defined in by
reference.
"""

from __future__ import annotations

from dataclasses import dataclass, field

from . import nodes as n
from .builtins import BUILTINS
from .commands import lookup_command
from .errors import KilnError, arg_error, arity_error, type_error
from .parser import parse_file
from .paths import is_reference, is_workspace_path
from .steps import Step, finish_step
from .values import interpolate, sort_key, type_name, values_equal, wrap
from .vfs import VirtualFS

MAX_RULE_DEPTH = 64


class Scope:
    """A mapping from names to values with a parent pointer."""

    __slots__ = ("vars", "parent")

    def __init__(self, parent: Scope | None = None) -> None:
        self.vars: dict[bytes, object] = {}
        self.parent = parent

    def lookup(self, name: bytes) -> object:
        scope: Scope | None = self
        while scope is not None:
            vars_ = scope.vars
            if name in vars_:
                return vars_[name]
            scope = scope.parent
        raise KilnError("E_UNKNOWN_VAR", name)

    def assign(self, name: bytes) -> Scope | None:
        """The innermost scope binding *name*, or ``None``."""
        scope: Scope | None = self
        while scope is not None:
            if name in scope.vars:
                return scope
            scope = scope.parent
        return None


@dataclass(slots=True)
class RuleDef:
    params: list[n.Param]
    body: list[n.Stmt]
    scope: Scope


@dataclass(slots=True)
class Evaluation:
    """The result of evaluating a workspace's build files."""

    steps: list[Step] = field(default_factory=list)
    #: Phony name (without ``@``) -> dependency references, in declaration order.
    phonies: dict[bytes, list[bytes]] = field(default_factory=dict)
    defaults: list[bytes] = field(default_factory=list)


def _int_div(a: int, b: int) -> int:
    q = abs(a) // abs(b)
    return -q if (a < 0) != (b < 0) else q


def _cmp_lt(a, b) -> bool:
    ta = type(a)
    if ta is type(b) and ta is not list:
        return a < b
    return sort_key(a) < sort_key(b)


def _cmp_le(a, b) -> bool:
    ta = type(a)
    if ta is type(b) and ta is not list:
        return a <= b
    return sort_key(a) <= sort_key(b)


_ARITH = {
    b"+": lambda a, b: wrap(a + b),
    b"-": lambda a, b: wrap(a - b),
    b"*": lambda a, b: wrap(a * b),
}


class Evaluator:
    """Evaluates build files against a virtual file system."""

    def __init__(self, vfs: VirtualFS) -> None:
        self.vfs = vfs  # also the ``env`` handed to ``glob``
        self.result = Evaluation()
        self.rules: dict[bytes, RuleDef] = {}
        self.include_stack: list[bytes] = []
        self.depth = 0
        self._expr = {
            n.Literal: self._literal,
            n.Interp: self._interp,
            n.Var: self._var,
            n.ListExpr: self._list,
            n.Unary: self._unary,
            n.Binary: self._binary,
            n.Index: self._index,
            n.Call: self._call,
        }
        self._stmt = {
            n.Let: self._let,
            n.Set: self._set,
            n.Include: self._include,
            n.Abort: self._abort,
            n.Default: self._default,
            n.Phony: self._phony,
            n.Use: self._use,
            n.When: self._when,
            n.Each: self._each,
            n.Rule: self._rule,
            n.Step: self._step,
        }

    # -- entry points ----------------------------------------------------------

    def run(self, path: bytes = b"main.kiln") -> Evaluation:
        """Evaluate the root build file at *path* (which must exist)."""
        root = Scope()
        self._run_file(path, root)
        return self.result

    def _run_file(self, path: bytes, scope: Scope) -> None:
        source = self.vfs.read(path)
        self.include_stack.append(path)
        try:
            stmts = parse_file(path, source)
            self.exec_block(stmts, scope)
        finally:
            self.include_stack.pop()

    # -- expressions -----------------------------------------------------------

    def eval(self, node: n.Expr, scope: Scope):
        return self._expr[type(node)](node, scope)

    def _literal(self, node: n.Literal, scope: Scope):
        return node.value

    def _interp(self, node: n.Interp, scope: Scope):
        out = []
        for part in node.parts:
            if type(part) is bytes:
                out.append(part)
            else:
                out.append(interpolate(self.eval(part, scope)))
        return b"".join(out)

    def _var(self, node: n.Var, scope: Scope):
        return scope.lookup(node.name)

    def _list(self, node: n.ListExpr, scope: Scope):
        return [self.eval(e, scope) for e in node.items]

    def _unary(self, node: n.Unary, scope: Scope):
        v = self.eval(node.operand, scope)
        if node.op == b"!":
            if type(v) is not bool:
                raise type_error("operator !", "bool", type_name(v))
            return not v
        if type(v) is not int:
            raise type_error("operator -", "int", type_name(v))
        return wrap(-v)

    def _binary(self, node: n.Binary, scope: Scope):
        op = node.op
        if op == b"||" or op == b"&&":
            left = self.eval(node.left, scope)
            if type(left) is not bool:
                raise type_error(f"operator {op.decode()}", "bool", type_name(left))
            if left == (op == b"||"):
                return left
            right = self.eval(node.right, scope)
            if type(right) is not bool:
                raise type_error(f"operator {op.decode()}", "bool", type_name(right))
            return right
        left = self.eval(node.left, scope)
        right = self.eval(node.right, scope)
        if op == b"==":
            return values_equal(left, right)
        if op == b"!=":
            return not values_equal(left, right)
        if op == b"<":
            return _cmp_lt(left, right)
        if op == b"<=":
            return _cmp_le(left, right)
        if op == b">":
            return _cmp_lt(right, left)
        if op == b">=":
            return _cmp_le(right, left)
        want = {b"++": "list", b"~": "str"}.get(op, "int")
        for operand in (left, right):
            if type_name(operand) != want:
                raise type_error(f"operator {op.decode()}", want, type_name(operand))
        if op == b"++":
            return left + right
        if op == b"~":
            return left + right
        if op in _ARITH:
            return _ARITH[op](left, right)
        if right == 0:
            raise KilnError("E_DIV_ZERO")
        quotient = _int_div(left, right)
        if op == b"/":
            return wrap(quotient)
        return wrap(left - quotient * right)

    def _index(self, node: n.Index, scope: Scope):
        target = self.eval(node.target, scope)
        idx = self.eval(node.index, scope)
        if type(idx) is not int:
            raise type_error("index", "int", type_name(idx))
        t = type(target)
        if t is not bytes and t is not list:
            raise type_error("index target", "str|list", type_name(target))
        size = len(target)
        if not -size <= idx < size:
            raise arg_error("fn", "index", "out of range")
        if idx < 0:
            idx += size
        return target[idx : idx + 1] if t is bytes else target[idx]

    def _call(self, node: n.Call, scope: Scope):
        fn = BUILTINS.get(node.name)
        if fn is None:
            raise KilnError("E_UNKNOWN_FUNC", node.name)
        args = [self.eval(a, scope) for a in node.args]
        if not fn.accepts(len(args)):
            raise arity_error("fn", fn.name, fn.arity_text(), len(args))
        fn.check_types(args)
        if fn.needs_env:
            return fn.impl(self, *args)
        return fn.impl(*args)

    @staticmethod
    def _expect(value, expected: str, site: str):
        actual = type_name(value)
        if actual != expected:
            raise type_error(site, expected, actual)
        return value

    @staticmethod
    def _strlist(value, site: str) -> list[bytes]:
        """A ``str`` or list of ``str`` as a list of byte strings."""
        t = type(value)
        if t is bytes:
            return [value]
        if t is list:
            for x in value:
                if type(x) is not bytes:
                    raise type_error(site, "strlist", type_name(x))
            return value
        raise type_error(site, "strlist", type_name(value))

    # -- statements ------------------------------------------------------------

    def exec_block(self, stmts: list[n.Stmt], scope: Scope) -> None:
        table = self._stmt
        for stmt in stmts:
            table[type(stmt)](stmt, scope)

    def _let(self, node: n.Let, scope: Scope) -> None:
        value = self.eval(node.expr, scope)
        if node.name in scope.vars:
            raise KilnError("E_REDEFINE", node.name)
        scope.vars[node.name] = value

    def _set(self, node: n.Set, scope: Scope) -> None:
        value = self.eval(node.expr, scope)
        target = scope.assign(node.name)
        if target is None:
            raise KilnError("E_SET_UNDEFINED", node.name)
        target.vars[node.name] = value

    def _include(self, node: n.Include, scope: Scope) -> None:
        path = self._expect(self.eval(node.expr, scope), "str", "include path")
        if not is_workspace_path(path):
            raise KilnError("E_BAD_PATH", path)
        if path not in self.vfs:
            raise KilnError("E_INCLUDE_MISSING", path)
        if path in self.include_stack:
            raise KilnError("E_INCLUDE_CYCLE", path)
        self._run_file(path, scope)

    def _abort(self, node: n.Abort, scope: Scope) -> None:
        msg = self._expect(self.eval(node.expr, scope), "str", "abort message")
        raise KilnError("E_ABORT", msg)

    def _default(self, node: n.Default, scope: Scope) -> None:
        names = self._strlist(self.eval(node.expr, scope), "default")
        self.result.defaults.extend(names)

    def _phony(self, node: n.Phony, scope: Scope) -> None:
        deps = self._strlist(self.eval(node.expr, scope), "phony " + node.name.decode())
        for dep in deps:
            if not is_reference(dep):
                raise KilnError("E_BAD_PATH", dep)
        if node.name in self.result.phonies:
            raise KilnError("E_DUP_PHONY", node.name)
        self.result.phonies[node.name] = list(deps)

    def _when(self, node: n.When, scope: Scope) -> None:
        for cond, body in node.branches:
            if self._expect(self.eval(cond, scope), "bool", "when condition"):
                self.exec_block(body, Scope(scope))
                return
        if node.otherwise is not None:
            self.exec_block(node.otherwise, Scope(scope))

    def _each(self, node: n.Each, scope: Scope) -> None:
        subject = self._expect(self.eval(node.subject, scope), "list", "each subject")
        for i, item in enumerate(subject):
            inner = Scope(scope)
            inner.vars[node.name] = item
            if node.index_name is not None:
                inner.vars[node.index_name] = i
            self.exec_block(node.body, inner)

    def _rule(self, node: n.Rule, scope: Scope) -> None:
        if node.name in self.rules:
            raise KilnError("E_REDEFINE", node.name)
        self.rules[node.name] = RuleDef(node.params, node.body, scope)

    def _use(self, node: n.Use, scope: Scope) -> None:
        rule = self.rules.get(node.name)
        if rule is None:
            raise KilnError("E_UNKNOWN_RULE", node.name)
        if self.depth + 1 > MAX_RULE_DEPTH:
            raise KilnError("E_RULE_RECURSION", node.name)
        positional: list = []
        keywords: list[tuple[bytes, object]] = []
        for kw, expr in node.args:
            value = self.eval(expr, scope)
            if kw is None:
                positional.append(value)
            else:
                keywords.append((kw, value))
        inner = Scope(rule.scope)
        params = rule.params
        if len(positional) > len(params):
            raise arity_error("rule", node.name, str(len(params)), len(positional))
        bound = inner.vars
        for param, value in zip(params, positional):
            bound[param.name] = value
        names = {p.name for p in params}
        for kw, value in keywords:
            if kw not in names:
                raise arg_error("rule", node.name, b"unknown argument " + kw)
            if kw in bound:
                raise arg_error("rule", node.name, b"duplicate argument " + kw)
            bound[kw] = value
        for param in params:
            if param.name in bound:
                continue
            if param.default is None:
                raise arg_error("rule", node.name, b"missing argument " + param.name)
            bound[param.name] = self.eval(param.default, inner)
        self.depth += 1
        self.exec_block(rule.body, inner)
        self.depth -= 1

    def _step(self, node: n.Step, scope: Scope) -> None:
        outs: list[bytes] = []
        ins: list[bytes] = []
        after: list[bytes] = []
        cost: int | None = None
        depfile: bytes | None = None
        spec = None
        cmd_args: tuple = ()
        for fld in node.fields:
            kind = fld.kind
            if kind == "cmd":
                if spec is not None:
                    raise KilnError("E_STEP_FIELD", "duplicate cmd")
                spec = lookup_command(fld.cmd_name)
                args = [self.eval(e, scope) for e in fld.cmd_args]
                spec.check_args(args)
                cmd_args = tuple(args)
            elif kind == "cost":
                if cost is not None:
                    raise KilnError("E_STEP_FIELD", "duplicate cost")
                value = self._expect(self.eval(fld.expr, scope), "int", "field cost")  # type: ignore[arg-type]
                if value < 0:
                    raise arg_error("field", "cost", "negative")
                cost = value
            elif kind == "depfile":
                if depfile is not None:
                    raise KilnError("E_STEP_FIELD", "duplicate depfile")
                depfile = self._expect(self.eval(fld.expr, scope), "str", "field depfile")  # type: ignore[arg-type]
            else:
                value = self.eval(fld.expr, scope)  # type: ignore[arg-type]
                refs = self._strlist(value, f"field {kind}")
                (outs if kind == "out" else ins if kind == "in" else after).extend(refs)
        step = finish_step(
            len(self.result.steps), outs, ins, after, cost, depfile, spec, cmd_args
        )
        self.result.steps.append(step)


def evaluate(vfs: VirtualFS, main: bytes = b"main.kiln") -> Evaluation:
    """Evaluate the build file *main* (and its includes) in *vfs*."""
    return Evaluator(vfs).run(main)
