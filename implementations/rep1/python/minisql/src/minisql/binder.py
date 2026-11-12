"""Binding: resolve names and run every semantic check before execution.

``bind`` turns a syntax tree into a plan. It raises :class:`SqlSemanticError`
for anything invalid, and never modifies the database, so a statement that
fails to bind has no effect.
"""

from __future__ import annotations

from typing import Mapping

from . import expr as ex
from . import syntax as sx
from .errors import SqlSemanticError
from .plan import (
    CreatePlan, DeletePlan, InsertPlan, OrderKey, Plan, SelectPlan, UpdatePlan,
)
from .table import Table

_ARITH_OPS = frozenset({"+", "-", "*", "/", "%"})
_CMP_OPS = frozenset({"=", "!=", "<", "<=", ">", ">="})


class _Source:
    """One table in a FROM clause: effective name, table and column offset."""

    __slots__ = ("name", "table", "offset")

    def __init__(self, name: str, table: Table, offset: int) -> None:
        self.name = name
        self.table = table
        self.offset = offset


class _Scope:
    """The tables visible to column references."""

    def __init__(self, sources: list[_Source]) -> None:
        self.sources = sources

    def local(self, i: int) -> "_Scope":
        """A scope with only source ``i``, its columns starting at 0."""
        src = self.sources[i]
        return _Scope([_Source(src.name, src.table, 0)])

    def resolve(self, qual: str | None, name: str) -> tuple[int, int]:
        """Return (source index, position in the concatenated row)."""
        if qual is not None:
            for i, src in enumerate(self.sources):
                if src.name == qual:
                    col = src.table.column_index(name)
                    if col is None:
                        raise SqlSemanticError(f"no such column: {qual}.{name}")
                    return i, src.offset + col
            raise SqlSemanticError(f"no such table in FROM: {qual}")
        found = []
        for i, src in enumerate(self.sources):
            col = src.table.column_index(name)
            if col is not None:
                found.append((i, src.offset + col))
        if not found:
            raise SqlSemanticError(f"no such column: {name}")
        if len(found) > 1:
            raise SqlSemanticError(f"ambiguous column: {name}")
        return found[0]


class _ExprBinder:
    """Binds expression syntax trees within one scope.

    ``aggregates`` is the list aggregate calls are appended to, or None if
    aggregates are not allowed. ``group_columns`` is None in a plain query; in
    an aggregate query it is the set of grouping column positions, the only
    columns allowed outside an aggregate call.
    """

    def __init__(
        self,
        scope: _Scope,
        aggregates: list[ex.AggregateSpec] | None = None,
        group_columns: set[int] | None = None,
    ) -> None:
        self.scope = scope
        self.aggregates = aggregates
        self.group_columns = group_columns

    def bind(self, node: sx.Node, in_aggregate: bool = False) -> ex.Expr:
        t = type(node)
        if t is sx.Lit:
            return ex.Literal(node.value)
        if t is sx.Col:
            _, index = self.scope.resolve(node.qual, node.name)
            if (
                self.group_columns is not None
                and not in_aggregate
                and index not in self.group_columns
            ):
                raise SqlSemanticError(
                    f"column {node.name} must be grouped or used in an aggregate"
                )
            return ex.Column(index)
        if t is sx.Neg:
            return ex.Negate(self.bind(node.operand, in_aggregate))
        if t is sx.Not:
            return ex.Not(self.bind(node.operand, in_aggregate))
        if t is sx.Bin:
            left = self.bind(node.left, in_aggregate)
            right = self.bind(node.right, in_aggregate)
            if node.op == "AND":
                return ex.And(left, right)
            if node.op == "OR":
                return ex.Or(left, right)
            if node.op in _ARITH_OPS:
                return ex.Arithmetic(node.op, left, right)
            return ex.Compare(node.op, left, right)
        if t is sx.IsNull:
            return ex.IsNull(self.bind(node.operand, in_aggregate), node.negated)
        if t is sx.Like:
            like = ex.Like(
                self.bind(node.operand, in_aggregate),
                self.bind(node.pattern, in_aggregate),
            )
            return ex.Not(like) if node.negated else like
        if t is sx.Agg:
            if self.aggregates is None:
                raise SqlSemanticError("aggregate function not allowed here")
            if in_aggregate:
                raise SqlSemanticError("aggregate functions cannot be nested")
            arg = None if node.arg is None else self.bind(node.arg, True)
            self.aggregates.append(ex.AggregateSpec(node.func, arg))
            return ex.AggregateRef(len(self.aggregates) - 1)
        raise AssertionError(f"unexpected node {node!r}")  # pragma: no cover


def bind(stmt: sx.Statement, tables: Mapping[str, Table]) -> Plan:
    """Bind a statement against the tables currently in the database."""
    if isinstance(stmt, sx.CreateTable):
        return _bind_create(stmt, tables)
    if isinstance(stmt, sx.Insert):
        return _bind_insert(stmt, tables)
    if isinstance(stmt, sx.Delete):
        return _bind_delete(stmt, tables)
    if isinstance(stmt, sx.Update):
        return _bind_update(stmt, tables)
    return _bind_select(stmt, tables)


def _lookup(tables: Mapping[str, Table], name: str) -> Table:
    table = tables.get(name)
    if table is None:
        raise SqlSemanticError(f"no such table: {name}")
    return table


def _bind_create(stmt: sx.CreateTable, tables: Mapping[str, Table]) -> CreatePlan:
    if stmt.name in tables:
        raise SqlSemanticError(f"table {stmt.name} already exists")
    if len(set(stmt.columns)) != len(stmt.columns):
        raise SqlSemanticError("duplicate column name")
    return CreatePlan(stmt.name, stmt.columns)


def _bind_insert(stmt: sx.Insert, tables: Mapping[str, Table]) -> InsertPlan:
    table = _lookup(tables, stmt.table)
    binder = _ExprBinder(_Scope([]))  # no columns, no aggregates
    rows = []
    for row in stmt.rows:
        if len(row) != len(table.columns):
            raise SqlSemanticError(
                f"table {table.name} has {len(table.columns)} columns "
                f"but {len(row)} values were supplied"
            )
        rows.append([binder.bind(e) for e in row])
    return InsertPlan(table, rows)


def _single_table_scope(table: Table) -> _Scope:
    return _Scope([_Source(table.name, table, 0)])


def _bind_delete(stmt: sx.Delete, tables: Mapping[str, Table]) -> DeletePlan:
    table = _lookup(tables, stmt.table)
    binder = _ExprBinder(_single_table_scope(table))
    where = None if stmt.where is None else binder.bind(stmt.where)
    return DeletePlan(table, where)


def _bind_update(stmt: sx.Update, tables: Mapping[str, Table]) -> UpdatePlan:
    table = _lookup(tables, stmt.table)
    binder = _ExprBinder(_single_table_scope(table))
    assignments = []
    for column, value in stmt.assignments:
        index = table.column_index(column)
        if index is None:
            raise SqlSemanticError(f"no such column: {column}")
        assignments.append((index, binder.bind(value)))
    where = None if stmt.where is None else binder.bind(stmt.where)
    return UpdatePlan(table, assignments, where)


# ------------------------------------------------------------------- SELECT


def _split_and(node: sx.Node | None) -> list[sx.Node]:
    """Flatten the top-level AND chain of ``node`` into its conjuncts."""
    if node is None:
        return []
    if type(node) is sx.Bin and node.op == "AND":
        return _split_and(node.left) + _split_and(node.right)
    return [node]


def _tables_used(node: sx.Node, scope: _Scope) -> set[int]:
    """Indexes of the sources whose columns ``node`` reads."""
    used = set()
    for n in sx.walk(node):
        if type(n) is sx.Col:
            used.add(scope.resolve(n.qual, n.name)[0])
    return used


def _bind_select(stmt: sx.Select, tables: Mapping[str, Table]) -> SelectPlan:
    # FROM
    sources: list[_Source] = []
    offset = 0
    for ref in stmt.tables:
        table = _lookup(tables, ref.name)
        if any(s.name == ref.effective_name for s in sources):
            raise SqlSemanticError(f"duplicate table name in FROM: {ref.effective_name}")
        sources.append(_Source(ref.effective_name, table, offset))
        offset += len(table.columns)
    scope = _Scope(sources)

    # Select list, with * expanded into one column reference per column.
    item_exprs: list[sx.Node] = []
    aliases: list[str | None] = []
    for item in stmt.items:
        if isinstance(item, sx.Star):
            if not sources:
                raise SqlSemanticError("* requires a FROM clause")
            for src in sources:
                for column in src.table.columns:
                    item_exprs.append(sx.Col(src.name, column))
                    aliases.append(None)
        else:
            item_exprs.append(item.expr)
            aliases.append(item.alias)

    # WHERE / ON: aggregates are not allowed; classify the conjuncts.
    conjuncts = _split_and(stmt.where) + _split_and(stmt.on)
    for c in conjuncts:
        if sx.contains_aggregate(c):
            raise SqlSemanticError("aggregate function not allowed in WHERE or ON")

    full = _ExprBinder(scope)
    local = [_ExprBinder(scope.local(i)) for i in range(len(sources))]
    const_filters: list[ex.Expr] = []
    filters: list[list[ex.Expr]] = [[] for _ in sources]
    hash_keys: list[tuple[ex.Expr, ex.Expr]] = []
    residual: list[ex.Expr] = []
    for c in conjuncts:
        used = _tables_used(c, scope)
        if not used:
            const_filters.append(full.bind(c))
        elif len(used) == 1:
            (i,) = used
            filters[i].append(local[i].bind(c))
        elif type(c) is sx.Bin and c.op == "=":
            lused = _tables_used(c.left, scope)
            rused = _tables_used(c.right, scope)
            if lused == {0} and rused == {1}:
                hash_keys.append((local[0].bind(c.left), local[1].bind(c.right)))
            elif lused == {1} and rused == {0}:
                hash_keys.append((local[0].bind(c.right), local[1].bind(c.left)))
            else:
                residual.append(full.bind(c))
        else:
            residual.append(full.bind(c))

    # Is this an aggregate query?
    order_exprs = [
        t.expr for t in stmt.order_by if t.ordinal is None and t.alias is None
    ]
    # A bare identifier may be an alias or a column; neither holds aggregates.
    aggregate = bool(stmt.group_by) or any(
        sx.contains_aggregate(n)
        for n in item_exprs + order_exprs + ([stmt.having] if stmt.having else [])
    )

    group_columns = [scope.resolve(g.qual, g.name)[1] for g in stmt.group_by]
    aggregates: list[ex.AggregateSpec] = []
    out = (
        _ExprBinder(scope, aggregates, set(group_columns))
        if aggregate
        else _ExprBinder(scope)
    )

    items = [out.bind(e) for e in item_exprs]
    having = None if stmt.having is None else out.bind(stmt.having)

    order: list[OrderKey] = []
    for term in stmt.order_by:
        if term.ordinal is not None:
            if not 1 <= term.ordinal <= len(items):
                raise SqlSemanticError(f"ORDER BY position {term.ordinal} out of range")
            order.append(OrderKey(term.ordinal - 1, None, term.descending))
        elif term.alias is not None and term.alias in aliases:
            order.append(OrderKey(aliases.index(term.alias), None, term.descending))
        else:
            order.append(OrderKey(None, out.bind(term.expr), term.descending))

    return SelectPlan(
        sources=[s.table for s in sources],
        const_filters=const_filters,
        filters=filters,
        hash_keys=hash_keys,
        residual=residual,
        aggregate=aggregate,
        group_columns=group_columns,
        aggregates=aggregates,
        items=items,
        having=having,
        order=order,
        limit=stmt.limit,
        offset=stmt.offset,
    )
