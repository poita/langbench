"""Rendering of types in the surface syntax."""

from __future__ import annotations

from .typerep import TVar, Type, resolve

# Contexts a type can be printed in.
_TOP = 0  # top level, or the right of an arrow: nothing needs parentheses
_LEFT = 1  # left of an arrow: functions need parentheses
_ATOM = 2  # tuple component or list element: functions and tuples do


def var_name(index: int) -> str:
    """Name of the ``index``-th (from 0) type variable: ``'a`` ... ``'z``, ``'a1`` ..."""
    letter = chr(ord("a") + index % 26)
    round_ = index // 26
    return f"'{letter}{round_}" if round_ else f"'{letter}"


def format_type(t: Type) -> str:
    """Render ``t``; variables are named in order of first appearance."""
    out: list[str] = []
    names: dict[int, str] = {}

    def write(t: Type, ctx: int) -> None:
        t = resolve(t)
        if t.__class__ is TVar:
            name = names.get(id(t))
            if name is None:
                name = names[id(t)] = var_name(len(names))
            out.append(name)
            return
        con = t.name  # type: ignore[attr-defined]
        args = t.args  # type: ignore[attr-defined]
        if con == "->":
            paren = ctx >= _LEFT
            if paren:
                out.append("(")
            write(args[0], _LEFT)
            out.append(" -> ")
            write(args[1], _TOP)
            if paren:
                out.append(")")
        elif con == "*":
            paren = ctx >= _ATOM
            if paren:
                out.append("(")
            for i, arg in enumerate(args):
                if i:
                    out.append(" * ")
                write(arg, _ATOM)
            if paren:
                out.append(")")
        elif con == "list":
            write(args[0], _ATOM)
            out.append(" list")
        else:
            out.append(con)

    write(t, _TOP)
    return "".join(out)
