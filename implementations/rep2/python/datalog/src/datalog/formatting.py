"""Rendering of query answers."""

from __future__ import annotations

from typing import Iterable

from .syntax import Constant


def format_tuple(predicate: str, row: Iterable[Constant]) -> str:
    """``p(v1, v2, ...)``"""
    return f"{predicate}({', '.join(map(str, row))})"
