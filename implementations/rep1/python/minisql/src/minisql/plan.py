"""Bound statements ("plans") produced by the binder and run by the executor."""

from __future__ import annotations

from dataclasses import dataclass, field

from .expr import AggregateSpec, Expr
from .table import Table


@dataclass(slots=True)
class CreatePlan:
    name: str
    columns: list[str]


@dataclass(slots=True)
class InsertPlan:
    table: Table
    rows: list[list[Expr]]


@dataclass(slots=True)
class DeletePlan:
    table: Table
    where: Expr | None


@dataclass(slots=True)
class UpdatePlan:
    table: Table
    assignments: list[tuple[int, Expr]]
    where: Expr | None


@dataclass(slots=True)
class OrderKey:
    """A bound ORDER BY term: either an output column or an expression."""

    output_index: int | None
    expr: Expr | None
    descending: bool


@dataclass(slots=True)
class SelectPlan:
    """A bound SELECT.

    The WHERE/ON conjuncts are pre-classified by the tables they read:

    * ``const_filters`` read no table;
    * ``filters[i]`` read only source ``i`` and are bound against that
      source's own row;
    * ``hash_keys`` are cross-table equalities ``(left, right)``, ``left``
      bound against source 0's row and ``right`` against source 1's;
    * ``residual`` are the remaining cross-table conjuncts, bound against the
      concatenated row of both sources.
    """

    sources: list[Table]
    const_filters: list[Expr]
    filters: list[list[Expr]]
    hash_keys: list[tuple[Expr, Expr]]
    residual: list[Expr]
    aggregate: bool
    group_columns: list[int]
    aggregates: list[AggregateSpec]
    items: list[Expr]
    having: Expr | None
    order: list[OrderKey]
    limit: int | None
    offset: int | None


Plan = CreatePlan | InsertPlan | DeletePlan | UpdatePlan | SelectPlan
