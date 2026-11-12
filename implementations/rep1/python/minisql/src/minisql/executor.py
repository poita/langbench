"""Plan execution: scans, hash joins, grouping, sorting."""

from __future__ import annotations

from functools import cmp_to_key
from typing import Sequence

from .expr import Expr
from .plan import (
    CreatePlan, DeletePlan, InsertPlan, Plan, SelectPlan, UpdatePlan,
)
from .table import Table
from .values import Value, compare, truth

Row = tuple[Value, ...]


def execute(plan: Plan, tables: dict[str, Table]) -> list[Row] | None:
    """Run a bound plan. Returns the rows of a SELECT, else None."""
    if isinstance(plan, SelectPlan):
        return _select(plan)
    if isinstance(plan, InsertPlan):
        new_rows = [tuple(e.eval((), None) for e in row) for row in plan.rows]
        plan.table.rows.extend(new_rows)
    elif isinstance(plan, DeletePlan):
        table = plan.table
        if plan.where is None:
            table.rows = []
        else:
            where = plan.where
            table.rows = [r for r in table.rows if truth(where.eval(r, None)) is not True]
    elif isinstance(plan, UpdatePlan):
        _update(plan)
    elif isinstance(plan, CreatePlan):
        tables[plan.name] = Table(plan.name, plan.columns)
    return None


def _update(plan: UpdatePlan) -> None:
    rows = plan.table.rows
    # Evaluate everything against the old rows first, then assign.
    changes: list[tuple[int, Row]] = []
    for i, row in enumerate(rows):
        if plan.where is not None and truth(plan.where.eval(row, None)) is not True:
            continue
        new = list(row)
        for index, expr in plan.assignments:
            new[index] = expr.eval(row, None)
        changes.append((i, tuple(new)))
    for i, new_row in changes:
        rows[i] = new_row


def _all_true(filters: Sequence[Expr], row: Row) -> bool:
    for f in filters:
        if truth(f.eval(row, None)) is not True:
            return False
    return True


def _candidate_rows(plan: SelectPlan) -> list[Row]:
    """Step 1-2 of SELECT: FROM, WHERE and ON, in nested-loop order."""
    if not _all_true(plan.const_filters, ()):
        return []
    if not plan.sources:
        return [()]
    kept = [
        [r for r in table.rows if _all_true(plan.filters[i], r)]
        for i, table in enumerate(plan.sources)
    ]
    if len(kept) == 1:
        return kept[0]
    outer, inner = kept
    residual = plan.residual
    out: list[Row] = []
    if plan.hash_keys:
        left_keys = [k[0] for k in plan.hash_keys]
        right_keys = [k[1] for k in plan.hash_keys]
        index: dict[tuple, list[Row]] = {}
        for r in inner:
            key = tuple([k.eval(r, None) for k in right_keys])
            if None not in key:
                index.setdefault(key, []).append(r)
        for r in outer:
            key = tuple([k.eval(r, None) for k in left_keys])
            if None in key:
                continue
            for m in index.get(key, ()):
                row = r + m
                if not residual or _all_true(residual, row):
                    out.append(row)
    else:
        for r in outer:
            for m in inner:
                row = r + m
                if not residual or _all_true(residual, row):
                    out.append(row)
    return out


def _compare_tuples(a: tuple, b: tuple) -> int:
    for x, y in zip(a, b):
        c = compare(x, y)
        if c:
            return c
    return 0


def _groups(plan: SelectPlan, rows: list[Row]) -> list[tuple[Row, list[Row]]]:
    """Step 3: partition rows into groups, in result order.

    Each group is (representative row, member rows); the representative
    supplies the grouping columns.
    """
    if not plan.group_columns:
        return [(rows[0] if rows else (), rows)]
    cols = plan.group_columns
    by_key: dict[tuple, list[Row]] = {}
    for r in rows:
        by_key.setdefault(tuple([r[c] for c in cols]), []).append(r)
    ordered = sorted(by_key, key=cmp_to_key(_compare_tuples))
    return [(by_key[k][0], by_key[k]) for k in ordered]


def _select(plan: SelectPlan) -> list[Row]:
    rows = _candidate_rows(plan)
    # Each entry: (row for evaluating expressions, aggregate results or None).
    contexts: list[tuple[Row, list[Value] | None]]
    if plan.aggregate:
        contexts = []
        for rep, members in _groups(plan, rows):
            aggs = [spec.compute(members) for spec in plan.aggregates]
            contexts.append((rep, aggs))
        if plan.having is not None:
            having = plan.having
            contexts = [c for c in contexts if truth(having.eval(*c)) is True]
    else:
        contexts = [(r, None) for r in rows]

    items = plan.items
    outputs: list[Row] = [tuple([e.eval(row, aggs) for e in items]) for row, aggs in contexts]

    if plan.order:
        order = plan.order
        keyed = []
        for out, (row, aggs) in zip(outputs, contexts):
            keys = [
                out[k.output_index] if k.expr is None else k.expr.eval(row, aggs)
                for k in order
            ]
            keyed.append((keys, out))
        descending = [k.descending for k in order]

        def cmp(a, b):
            for x, y, desc in zip(a[0], b[0], descending):
                c = compare(x, y)
                if c:
                    return -c if desc else c
            return 0

        keyed.sort(key=cmp_to_key(cmp))  # one stable comparison sort
        outputs = [out for _, out in keyed]

    start = plan.offset or 0
    if plan.limit is None:
        return outputs[start:] if start else outputs
    return outputs[start : start + plan.limit]
