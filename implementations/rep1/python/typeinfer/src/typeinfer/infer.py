"""Algorithm J: single-pass, left-to-right inference with in-place unification."""

from __future__ import annotations

from dataclasses import dataclass

from .builtins import initial_bindings
from .env import Env
from .errors import TypeCheckError, UnboundVariableError
from .parser import parse_program
from .pretty import format_type
from .scheme import generalize, instantiate
from .syntax import (
    App,
    BinOp,
    BoolLit,
    Cons,
    Decl,
    Expr,
    Fun,
    If,
    IntLit,
    Let,
    LetRec,
    ListLit,
    NilLit,
    Tuple,
    UnitLit,
    Var,
)
from .typerep import BOOL, INT, UNIT, Scheme, TCon, TVar, Type, arrow, list_of, tuple_of
from .unify import unify

# operator -> (operand type, result type)
_OPERATORS: dict[str, tuple[Type, Type]] = {
    **{op: (INT, INT) for op in ("+", "-", "*", "/")},
    **{op: (INT, BOOL) for op in ("=", "<", ">", "<=", ">=")},
    **{op: (BOOL, BOOL) for op in ("&&", "||")},
}


@dataclass(frozen=True, slots=True)
class DeclResult:
    """Outcome of checking one declaration.

    ``name`` is the bound name (``None`` for a bare expression).  Exactly one of
    ``type`` and ``error`` is set; ``error`` is ``"unify"``, ``"occurs"`` or
    ``"unbound"``.
    """

    name: str | None
    type: Type | None = None
    error: str | None = None

    @property
    def ok(self) -> bool:
        return self.error is None

    def render(self) -> str:
        """The output line for this declaration (without the newline)."""
        if self.error is not None:
            return f"error: {self.error}"
        assert self.type is not None
        return f"{self.name or '-'} : {format_type(self.type)}"


class Inferencer:
    """Type checker holding the top-level environment across declarations."""

    def __init__(self) -> None:
        self.env = Env(initial_bindings())
        self.level = 0
        self._dispatch = {
            IntLit: self._int,
            BoolLit: self._bool,
            UnitLit: self._unit,
            NilLit: self._nil,
            Var: self._var,
            Tuple: self._tuple,
            ListLit: self._list,
            Fun: self._fun,
            App: self._app,
            If: self._if,
            Let: self._let,
            LetRec: self._letrec,
            BinOp: self._binop,
            Cons: self._cons,
        }

    # -- public ----------------------------------------------------------

    def check_decl(self, decl: Decl) -> DeclResult:
        """Check one declaration; on success a ``let`` extends the environment."""
        env = self.env
        env.rollback(0)
        self.level = 1
        try:
            if decl.recursive:
                t = self._rec_binding(decl.name, decl.expr)  # type: ignore[arg-type]
            else:
                t = self.infer(decl.expr)
        except TypeCheckError as exc:
            env.rollback(0)
            self.level = 0
            return DeclResult(decl.name, error=exc.kind)
        self.level = 0
        env.rollback(0)
        if decl.name is None:
            return DeclResult(None, t)
        env.bind(decl.name, Scheme(t, generalize(t, 0)))
        env.commit()
        return DeclResult(decl.name, t)

    def infer(self, expr: Expr) -> Type:
        """Infer the type of ``expr`` in the current environment."""
        return self._dispatch[expr.__class__](expr)

    # -- expressions -----------------------------------------------------

    def _fresh(self) -> TVar:
        return TVar(self.level)

    def _int(self, e: IntLit) -> Type:
        return INT

    def _bool(self, e: BoolLit) -> Type:
        return BOOL

    def _unit(self, e: UnitLit) -> Type:
        return UNIT

    def _nil(self, e: NilLit) -> Type:
        return list_of(TVar(self.level))

    def _var(self, e: Var) -> Type:
        scheme = self.env.table.get(e.name)
        if scheme is None:
            raise UnboundVariableError(e.name)
        if scheme.poly:
            return instantiate(scheme.type, self.level)
        return scheme.type

    def _tuple(self, e: Tuple) -> Type:
        infer = self.infer
        return tuple_of([infer(item) for item in e.items])

    def _list(self, e: ListLit) -> Type:
        elem = TVar(self.level)
        infer = self.infer
        for item in e.items:
            unify(elem, infer(item))
        return list_of(elem)

    def _fun(self, e: Fun) -> Type:
        env = self.env
        mark = env.mark()
        level = self.level
        param_types = []
        for name in e.params:
            tv = TVar(level)
            param_types.append(tv)
            env.bind(name, Scheme(tv))
        result = self.infer(e.body)
        env.rollback(mark)
        for tv in reversed(param_types):
            result = arrow(tv, result)
        return result

    def _app(self, e: App) -> Type:
        infer = self.infer
        t = infer(e.func)
        for arg in e.args:
            ta = infer(arg)
            result = TVar(self.level)
            unify(t, arrow(ta, result))
            t = result
        return t

    def _if(self, e: If) -> Type:
        unify(self.infer(e.cond), BOOL)
        ta = self.infer(e.then)
        tb = self.infer(e.orelse)
        unify(ta, tb)
        return ta

    def _let(self, e: Let) -> Type:
        self.level += 1
        t1 = self.infer(e.value)
        self.level -= 1
        scheme = Scheme(t1, generalize(t1, self.level))
        env = self.env
        mark = env.mark()
        env.bind(e.name, scheme)
        t = self.infer(e.body)
        env.rollback(mark)
        return t

    def _rec_binding(self, name: str, fun: Fun) -> Type:
        """Infer ``fun`` with ``name`` bound monomorphically to itself.

        Must be called one level deeper than the binding being generalised;
        the caller is responsible for the level.  Returns the type of ``name``.
        """
        env = self.env
        mark = env.mark()
        tf = TVar(self.level)
        env.bind(name, Scheme(tf))
        t = self.infer(fun)
        unify(tf, t)
        env.rollback(mark)
        return tf

    def _letrec(self, e: LetRec) -> Type:
        self.level += 1
        tf = self._rec_binding(e.name, e.value)
        self.level -= 1
        scheme = Scheme(tf, generalize(tf, self.level))
        env = self.env
        mark = env.mark()
        env.bind(e.name, scheme)
        t = self.infer(e.body)
        env.rollback(mark)
        return t

    def _binop(self, e: BinOp) -> Type:
        operand, result = _OPERATORS[e.op]
        unify(self.infer(e.left), operand)
        unify(self.infer(e.right), operand)
        return result

    def _cons(self, e: Cons) -> Type:
        head = self.infer(e.head)
        tail = self.infer(e.tail)
        unify(tail, list_of(head))
        return list_of(head)


def infer_program(source: str) -> list[DeclResult]:
    """Parse and check a whole program, returning one result per declaration."""
    inferencer = Inferencer()
    return [inferencer.check_decl(decl) for decl in parse_program(source)]


def infer_type(source: str) -> str:
    """Parse the single expression ``source`` and return its printed type.

    Raises :class:`TypeCheckError` if it does not type-check.
    """
    from .parser import parse_expr

    inferencer = Inferencer()
    inferencer.level = 1
    return format_type(inferencer.infer(parse_expr(source)))
