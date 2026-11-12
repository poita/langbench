"""The KBL interpreter: executes build files into a :class:`Program`.

A :class:`Program` is the evaluation result a build needs: the ordered step
list, the phony table and the default target list.  Evaluation never mutates
the workspace.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any, Callable

from . import nodes as N
from .builtins import Builtin, make_builtins
from .errors import KilnError, type_error
from .parser import parse_file
from .paths import BUILD_FILE, is_workspace_path
from .steps import Step, StepBuilder, check_reference_shape
from .values import equal, sort_key, stringify, type_name, wrap_int
from .vfs import VirtualFS

__all__ = ["Program", "evaluate", "MAX_RULE_DEPTH"]

#: The deepest permitted nesting of rule instantiations.
MAX_RULE_DEPTH = 64


@dataclass
class Program:
    """The result of evaluating a workspace's build files."""

    steps: list[Step] = field(default_factory=list)
    #: phony name (without ``@``) -> dependency strings, in declaration order
    phonies: dict[bytes, list[bytes]] = field(default_factory=dict)
    defaults: list[bytes] = field(default_factory=list)


class Scope:
    """A lexical scope: a name->value map with a parent pointer."""

    __slots__ = ("vars", "parent")

    def __init__(self, parent: "Scope | None" = None) -> None:
        self.vars: dict[bytes, Any] = {}
        self.parent = parent


@dataclass(slots=True)
class _Rule:
    node: N.RuleDef
    scope: Scope


def _strlist(value: Any, site: str | bytes) -> list[bytes]:
    """``value`` as a list of str, or ``E_TYPE <site>: expected strlist``."""
    t = type(value)
    if t is bytes:
        return [value]
    if t is list:
        for e in value:
            if type(e) is not bytes:
                raise type_error(site, "strlist", type_name(e))
        return value
    raise type_error(site, "strlist", type_name(value))


def _require(value: Any, want: type, token: str, site: str) -> None:
    if type(value) is not want:
        raise type_error(site, token, type_name(value))


def _int_op(op: str, f: Callable[[int, int], int]) -> Callable[[Any, Any], int]:
    site = "operator " + op

    def run(l: Any, r: Any) -> int:
        if type(l) is not int:
            raise type_error(site, "int", type_name(l))
        if type(r) is not int:
            raise type_error(site, "int", type_name(r))
        return wrap_int(f(l, r))

    return run


def _div(a: int, b: int) -> int:
    if b == 0:
        raise KilnError("E_DIV_ZERO")
    q = abs(a) // abs(b)
    return q if (a < 0) == (b < 0) else -q


def _mod(a: int, b: int) -> int:
    if b == 0:
        raise KilnError("E_DIV_ZERO")
    return a - _div(a, b) * b


def _typed_op(op: str, py: type, token: str, f: Callable[[Any, Any], Any]) -> Callable[[Any, Any], Any]:
    site = "operator " + op

    def run(l: Any, r: Any) -> Any:
        if type(l) is not py:
            raise type_error(site, token, type_name(l))
        if type(r) is not py:
            raise type_error(site, token, type_name(r))
        return f(l, r)

    return run


def _ordered(f: Callable[[Any, Any], bool]) -> Callable[[Any, Any], bool]:
    def run(l: Any, r: Any) -> bool:
        tl = type(l)
        if tl is type(r) and (tl is int or tl is bytes):
            return f(l, r)
        return f(sort_key(l), sort_key(r))

    return run


_BINARY_OPS: dict[str, Callable[[Any, Any], Any]] = {
    "+": _int_op("+", lambda a, b: a + b),
    "-": _int_op("-", lambda a, b: a - b),
    "*": _int_op("*", lambda a, b: a * b),
    "/": _int_op("/", _div),
    "%": _int_op("%", _mod),
    "~": _typed_op("~", bytes, "str", lambda a, b: a + b),
    "++": _typed_op("++", list, "list", lambda a, b: a + b),
    "==": equal,
    "!=": lambda a, b: not equal(a, b),
    "<": _ordered(lambda a, b: a < b),
    "<=": _ordered(lambda a, b: a <= b),
    ">": _ordered(lambda a, b: a > b),
    ">=": _ordered(lambda a, b: a >= b),
}


class Interpreter:
    """Executes parsed build files against a :class:`~kiln.vfs.VirtualFS`."""

    def __init__(self, fs: VirtualFS) -> None:
        self.fs = fs
        self.builtins: dict[bytes, Builtin] = make_builtins(fs)
        self.program = Program()
        self.rules: dict[bytes, _Rule] = {}
        self.include_stack: list[bytes] = []
        self.depth = 0
        self._expr: dict[type, Callable[[Any, Scope], Any]] = {
            N.Lit: lambda n, s: n.value,
            N.Interp: self._interp,
            N.Var: self._var,
            N.ListLit: self._list,
            N.Unary: self._unary,
            N.Binary: self._binary,
            N.Call: self._call,
            N.Index: self._index,
        }
        self._stmt: dict[type, Callable[[Any, Scope], None]] = {
            N.Let: self._let,
            N.Set: self._set,
            N.Include: self._include,
            N.Abort: self._abort,
            N.Default: self._default,
            N.Phony: self._phony,
            N.Use: self._use,
            N.When: self._when,
            N.Each: self._each,
            N.RuleDef: self._rule,
            N.StepBlock: self._step,
        }

    # ---- entry points -----------------------------------------------------------

    def run_file(self, path: bytes, scope: Scope) -> None:
        """Lex, parse and execute the build file at ``path`` in ``scope``."""
        source = self.fs.read(path)
        assert source is not None
        body = parse_file(path, source)
        self.include_stack.append(path)
        try:
            self.exec_body(body, scope)
        finally:
            self.include_stack.pop()

    def exec_body(self, body: tuple, scope: Scope) -> None:
        table = self._stmt
        for stmt in body:
            table[type(stmt)](stmt, scope)

    def eval(self, node: Any, scope: Scope) -> Any:
        return self._expr[type(node)](node, scope)

    # ---- expressions ---------------------------------------------------------------

    def _var(self, node: N.Var, scope: Scope) -> Any:
        name = node.name
        s: Scope | None = scope
        while s is not None:
            v = s.vars
            if name in v:
                return v[name]
            s = s.parent
        raise KilnError("E_UNKNOWN_VAR", name)

    def _list(self, node: N.ListLit, scope: Scope) -> list:
        ev = self._expr
        return [ev[type(e)](e, scope) for e in node.items]

    def _interp(self, node: N.Interp, scope: Scope) -> bytes:
        out = []
        for part in node.parts:
            if type(part) is bytes:
                out.append(part)
            else:
                out.append(stringify(self.eval(part, scope)))
        return b"".join(out)

    def _unary(self, node: N.Unary, scope: Scope) -> Any:
        v = self.eval(node.operand, scope)
        if node.op == "!":
            if type(v) is not bool:
                raise type_error("operator !", "bool", type_name(v))
            return not v
        if type(v) is not int:
            raise type_error("operator -", "int", type_name(v))
        return wrap_int(-v)

    def _binary(self, node: N.Binary, scope: Scope) -> Any:
        op = node.op
        if op == "||" or op == "&&":
            l = self.eval(node.left, scope)
            if type(l) is not bool:
                raise type_error("operator " + op, "bool", type_name(l))
            if l == (op == "||"):
                return l
            r = self.eval(node.right, scope)
            if type(r) is not bool:
                raise type_error("operator " + op, "bool", type_name(r))
            return r
        l = self.eval(node.left, scope)
        r = self.eval(node.right, scope)
        return _BINARY_OPS[op](l, r)

    def _call(self, node: N.Call, scope: Scope) -> Any:
        fn = self.builtins.get(node.name)
        if fn is None:
            raise KilnError("E_UNKNOWN_FUNC", node.name)
        ev = self._expr
        args = [ev[type(a)](a, scope) for a in node.args]
        return fn.call(args)

    def _index(self, node: N.Index, scope: Scope) -> Any:
        target = self.eval(node.target, scope)
        idx = self.eval(node.index, scope)
        if type(idx) is not int:
            raise type_error("index", "int", type_name(idx))
        t = type(target)
        if t is not bytes and t is not list:
            raise type_error("index target", "str|list", type_name(target))
        n = len(target)
        if idx < -n or idx >= n:
            raise KilnError("E_ARG", "fn index: out of range")
        if idx < 0:
            idx += n
        return target[idx:idx + 1] if t is bytes else target[idx]

    # ---- statements -------------------------------------------------------------------

    def _let(self, node: N.Let, scope: Scope) -> None:
        value = self.eval(node.expr, scope)
        if node.name in scope.vars:
            raise KilnError("E_REDEFINE", node.name)
        scope.vars[node.name] = value

    def _set(self, node: N.Set, scope: Scope) -> None:
        value = self.eval(node.expr, scope)
        s: Scope | None = scope
        while s is not None:
            if node.name in s.vars:
                s.vars[node.name] = value
                return
            s = s.parent
        raise KilnError("E_SET_UNDEFINED", node.name)

    def _include(self, node: N.Include, scope: Scope) -> None:
        path = self.eval(node.expr, scope)
        _require(path, bytes, "str", "include path")
        if not is_workspace_path(path):
            raise KilnError("E_BAD_PATH", path)
        if not self.fs.exists(path):
            raise KilnError("E_INCLUDE_MISSING", path)
        if path in self.include_stack:
            raise KilnError("E_INCLUDE_CYCLE", path)
        self.run_file(path, scope)

    def _abort(self, node: N.Abort, scope: Scope) -> None:
        msg = self.eval(node.expr, scope)
        _require(msg, bytes, "str", "abort message")
        raise KilnError("E_ABORT", msg)

    def _default(self, node: N.Default, scope: Scope) -> None:
        value = self.eval(node.expr, scope)
        self.program.defaults.extend(_strlist(value, "default"))

    def _phony(self, node: N.Phony, scope: Scope) -> None:
        value = self.eval(node.expr, scope)
        deps = _strlist(value, b"phony " + node.name)
        for d in deps:
            check_reference_shape(d)
        if node.name in self.program.phonies:
            raise KilnError("E_DUP_PHONY", node.name)
        self.program.phonies[node.name] = list(deps)

    def _when(self, node: N.When, scope: Scope) -> None:
        for cond, body in node.branches:
            if cond is not None:
                c = self.eval(cond, scope)
                if type(c) is not bool:
                    raise type_error("when condition", "bool", type_name(c))
                if not c:
                    continue
            self.exec_body(body, Scope(scope))
            return

    def _each(self, node: N.Each, scope: Scope) -> None:
        subject = self.eval(node.subject, scope)
        _require(subject, list, "list", "each subject")
        name, index_name, body = node.name, node.index_name, node.body
        for i, element in enumerate(subject):
            inner = Scope(scope)
            if index_name is not None:
                inner.vars[index_name] = i
            inner.vars[name] = element
            self.exec_body(body, inner)

    def _rule(self, node: N.RuleDef, scope: Scope) -> None:
        if node.name in self.rules:
            raise KilnError("E_REDEFINE", node.name)
        self.rules[node.name] = _Rule(node, scope)

    def _use(self, node: N.Use, scope: Scope) -> None:
        rule = self.rules.get(node.name)
        if rule is None:
            raise KilnError("E_UNKNOWN_RULE", node.name)
        if self.depth + 1 > MAX_RULE_DEPTH:
            raise KilnError("E_RULE_RECURSION", node.name)
        args = [self.eval(a, scope) for a in node.args]
        kwargs = [(k, self.eval(e, scope)) for k, e in node.kwargs]
        params = rule.node.params
        inner = Scope(rule.scope)
        if len(args) > len(params):
            raise KilnError("E_ARITY", b"rule %b: expected %d, got %d" % (node.name, len(params), len(args)))
        bound = inner.vars
        for p, v in zip(params, args):
            bound[p.name] = v
        names = {p.name for p in params}
        for k, v in kwargs:
            if k not in names:
                raise KilnError("E_ARG", b"rule %b: unknown argument %b" % (node.name, k))
            if k in bound:
                raise KilnError("E_ARG", b"rule %b: duplicate argument %b" % (node.name, k))
            bound[k] = v
        for p in params:
            if p.name in bound:
                continue
            if p.default is None:
                raise KilnError("E_ARG", b"rule %b: missing argument %b" % (node.name, p.name))
            bound[p.name] = self.eval(p.default, inner)
        self.depth += 1
        try:
            self.exec_body(rule.node.body, inner)
        finally:
            self.depth -= 1

    def _step(self, node: N.StepBlock, scope: Scope) -> None:
        b = StepBuilder()
        for f in node.fields:
            if type(f) is N.CmdField:
                b.check_duplicate(b"cmd")
                spec = b.lookup_command(f.name)
                b.set_command(spec, [self.eval(a, scope) for a in f.args])
                continue
            kind = f.kind
            if kind == b"cost" or kind == b"depfile":
                b.check_duplicate(kind)
                value = self.eval(f.expr, scope)
                if kind == b"cost":
                    b.set_cost(value)
                else:
                    b.set_depfile(value)
            else:
                b.add_list(kind, self.eval(f.expr, scope))
        self.program.steps.append(b.finish(len(self.program.steps)))


def evaluate(fs: VirtualFS, main: bytes = BUILD_FILE) -> Program:
    """Evaluate the build file ``main`` (and its includes) against ``fs``.

    Raises :class:`~kiln.errors.KilnError` for the first error in execution
    order.  The workspace is not modified.
    """
    interp = Interpreter(fs)
    interp.run_file(main, Scope())
    return interp.program
