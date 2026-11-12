"""Syntax tree for Vellum (SPEC section 4).

Every node carries ``pos``, a module-local ``(line, col)`` pair.  Fields after the
syntactic ones, declared with defaults, are annotations filled in by the checker.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any

Pos = tuple[int, int]


@dataclass(slots=True, eq=False)
class Node:
    pos: Pos


# ---------------------------------------------------------------- types ----
@dataclass(slots=True, eq=False)
class TyName(Node):
    qual: str | None
    qual_pos: Pos | None
    name: str
    name_pos: Pos
    args: list | None


@dataclass(slots=True, eq=False)
class TyList(Node):
    elem: Any


@dataclass(slots=True, eq=False)
class TyMap(Node):
    key: Any
    value: Any


@dataclass(slots=True, eq=False)
class TyTuple(Node):
    items: list


@dataclass(slots=True, eq=False)
class TyFn(Node):
    params: list
    ret: Any  # None means Unit


# ------------------------------------------------------------- patterns ----
@dataclass(slots=True, eq=False)
class PWild(Node):
    pass


@dataclass(slots=True, eq=False)
class PBind(Node):
    """A bare identifier: a binding, or a zero-payload variant (decided by the checker)."""

    name: str
    var: Any = None
    variant: Any = None
    ty: Any = None


@dataclass(slots=True, eq=False)
class PLit(Node):
    kind: str  # int float str char bool
    value: Any
    ty: Any = None


@dataclass(slots=True, eq=False)
class PTuple(Node):
    items: list
    ty: Any = None


@dataclass(slots=True, eq=False)
class PList(Node):
    items: list
    has_rest: bool
    rest_name: str | None
    rest_pos: Pos | None
    rest_var: Any = None
    ty: Any = None


@dataclass(slots=True, eq=False)
class PVariant(Node):
    qual: str | None
    qual_pos: Pos | None
    name: str
    name_pos: Pos
    args: list | None
    variant: Any = None
    ty: Any = None


@dataclass(slots=True, eq=False)
class PStruct(Node):
    qual: str | None
    qual_pos: Pos | None
    name: str
    name_pos: Pos
    fields: list  # of FieldPat
    rest: bool
    decl: Any = None
    ty: Any = None


@dataclass(slots=True, eq=False)
class FieldPat:
    name: str
    pos: Pos
    pat: Any  # pattern or None (shorthand)
    index: int = -1
    var: Any = None


# ---------------------------------------------------------- expressions ----
@dataclass(slots=True, eq=False)
class IntLit(Node):
    value: int


@dataclass(slots=True, eq=False)
class FloatLit(Node):
    value: float


@dataclass(slots=True, eq=False)
class StrLit(Node):
    value: str


@dataclass(slots=True, eq=False)
class CharLit(Node):
    value: str


@dataclass(slots=True, eq=False)
class BoolLit(Node):
    value: bool


@dataclass(slots=True, eq=False)
class SelfExpr(Node):
    var: Any = None


@dataclass(slots=True, eq=False)
class PathExpr(Node):
    qual: str | None
    qual_pos: Pos | None
    name: str
    name_pos: Pos
    res: Any = None  # ('local', var) | ('variant', v) ...


@dataclass(slots=True, eq=False)
class StructLit(Node):
    path: PathExpr
    fields: list  # of FieldInit
    decl: Any = None
    perm: Any = None


@dataclass(slots=True, eq=False)
class FieldInit:
    name: str
    pos: Pos
    expr: Any


@dataclass(slots=True, eq=False)
class Unary(Node):
    op: str
    operand: Any
    tag: str = ""


@dataclass(slots=True, eq=False)
class Binary(Node):
    op: str
    left: Any
    right: Any
    tag: str = ""


@dataclass(slots=True, eq=False)
class Call(Node):
    callee: Any
    args: list
    kind: str = ""  # direct builtin variant value
    target: Any = None


@dataclass(slots=True, eq=False)
class MethodCall(Node):
    recv: Any
    name: str
    name_pos: Pos
    args: list
    trait: Any = None
    midx: int = -1
    target: Any = None  # statically resolved FuncInfo or None for dynamic dispatch
    path_form: bool = False  # Tr::m(recv, ...)


@dataclass(slots=True, eq=False)
class Index(Node):
    base: Any
    index: Any
    tag: str = ""


@dataclass(slots=True, eq=False)
class FieldAccess(Node):
    obj: Any
    name: str
    name_pos: Pos
    index: int = -1


@dataclass(slots=True, eq=False)
class ListLit(Node):
    items: list


@dataclass(slots=True, eq=False)
class MapLit(Node):
    entries: list  # of (key, value)


@dataclass(slots=True, eq=False)
class TupleLit(Node):
    items: list


@dataclass(slots=True, eq=False)
class LParam:
    name: str
    pos: Pos
    ty: Any  # syntactic type or None
    var: Any = None


@dataclass(slots=True, eq=False)
class Lambda(Node):
    params: list
    ret: Any
    body: Any  # Block or expression
    ctx: Any = None


@dataclass(slots=True, eq=False)
class If(Node):
    cond: Any
    then: Any
    els: Any  # Block, If or None


@dataclass(slots=True, eq=False)
class Arm:
    pat: Any
    guard: Any
    body: Any
    pos: Pos


@dataclass(slots=True, eq=False)
class Match(Node):
    scrut: Any
    arms: list


@dataclass(slots=True, eq=False)
class Block(Node):
    stmts: list
    tail: Any  # expression or None


# ----------------------------------------------------------- statements ----
@dataclass(slots=True, eq=False)
class Let(Node):
    pat: Any
    ty: Any
    expr: Any


@dataclass(slots=True, eq=False)
class VarDecl(Node):
    name: str
    name_pos: Pos
    ty: Any
    expr: Any
    var: Any = None


@dataclass(slots=True, eq=False)
class Assign(Node):
    target: Any
    expr: Any
    var: Any = None
    tag: str = ""


@dataclass(slots=True, eq=False)
class ExprStmt(Node):
    expr: Any


@dataclass(slots=True, eq=False)
class Return(Node):
    expr: Any


@dataclass(slots=True, eq=False)
class While(Node):
    cond: Any
    body: Block


@dataclass(slots=True, eq=False)
class For(Node):
    pat: Any
    iter: Any
    hi: Any
    body: Block
    tag: str = ""  # list str range


@dataclass(slots=True, eq=False)
class Break(Node):
    pass


@dataclass(slots=True, eq=False)
class Continue(Node):
    pass


# ---------------------------------------------------------------- items ----
@dataclass(slots=True, eq=False)
class TraitRef(Node):
    qual: str | None
    qual_pos: Pos | None
    name: str
    name_pos: Pos


@dataclass(slots=True, eq=False)
class GenParam:
    name: str
    pos: Pos
    bounds: list  # of TraitRef


@dataclass(slots=True, eq=False)
class Param:
    name: str
    pos: Pos
    ty: Any


@dataclass(slots=True, eq=False)
class Use(Node):
    module: str
    module_pos: Pos
    alias: str | None
    alias_pos: Pos | None


@dataclass(slots=True, eq=False)
class FnDecl(Node):
    name: str
    name_pos: Pos
    tparams: list
    params: list
    ret: Any
    body: Block
    pub: bool


@dataclass(slots=True, eq=False)
class FieldDecl:
    name: str
    pos: Pos
    ty: Any


@dataclass(slots=True, eq=False)
class StructDecl(Node):
    name: str
    name_pos: Pos
    tparams: list
    fields: list
    pub: bool


@dataclass(slots=True, eq=False)
class VariantDecl:
    name: str
    pos: Pos
    payloads: list


@dataclass(slots=True, eq=False)
class EnumDecl(Node):
    name: str
    name_pos: Pos
    tparams: list
    variants: list
    pub: bool


@dataclass(slots=True, eq=False)
class MethodDecl(Node):
    name: str
    name_pos: Pos
    params: list  # excluding self
    ret: Any
    body: Block | None


@dataclass(slots=True, eq=False)
class TraitDecl(Node):
    name: str
    name_pos: Pos
    methods: list
    pub: bool


@dataclass(slots=True, eq=False)
class ImplDecl(Node):
    tparams: list
    trait: TraitRef
    head: Any
    methods: list
