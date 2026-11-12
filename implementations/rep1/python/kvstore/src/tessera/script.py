"""Running ``commands.txt`` scripts and formatting ``results.txt`` (SPEC §19)."""

from __future__ import annotations

from .database import Database
from .errors import TesseraError
from .parser import (CreateIndex, Delete, DropIndex, Find, Get, Put, Scan, Simple, Unset,
                     Update, parse_command)
from .value import render, render_string


def _key(raw: bytes) -> str:
    return render_string(raw.decode("utf-8", "replace"))


def execute(db: Database, cmd) -> list[str]:
    """Run a parsed command; returns the status text followed by the payload lines."""
    t = type(cmd)
    if t is Simple:
        name = cmd.name
        if name == "begin":
            db.begin()
            return ["ok begin"]
        if name == "commit":
            txn_id, frames = db.commit()
            return [f"ok commit {txn_id} frames {frames}"]
        if name == "rollback":
            db.rollback()
            return ["ok rollback"]
        if name == "checkpoint":
            return [f"ok checkpoint pages {db.checkpoint()}"]
        if name == "indexes":
            infos = db.indexes()
            return [f"ok indexes {len(infos)}"] + [
                f"  {i.slot} {i.path} root {i.root} entries {i.entries}" for i in infos]
        s = db.stat()
        return ["ok stat", f"  pages {s.pages}", f"  free {s.free}", f"  freehead {s.freehead}",
                f"  docs {s.docs}", f"  root {s.root}", f"  height {s.height}",
                f"  commits {s.commits}", f"  indexes {s.indexes}", f"  wal {s.wal}"]
    if t is Put:
        return ["ok put created" if db.put(cmd.key, cmd.value) else "ok put replaced"]
    if t is Get:
        return ["ok get value", "  " + render(db.get(cmd.key))]
    if t is Delete:
        db.delete(cmd.key)
        return ["ok delete removed"]
    if t is Update:
        db.update(cmd.key, cmd.segs, cmd.value)
        return ["ok update updated"]
    if t is Unset:
        db.unset(cmd.key, cmd.segs)
        return ["ok unset updated"]
    if t is Scan:
        rows = db.scan(cmd.start, cmd.stop, cmd.limit, cmd.reverse, cmd.keys_only)
        if cmd.keys_only:
            return [f"ok scan {len(rows)}"] + ["  " + _key(k) for k in rows]
        return [f"ok scan {len(rows)}"] + [f"  {_key(k)} = {render(d)}" for k, d in rows]
    if t is Find:
        res = db.find(cmd.pred, cmd.limit)
        return [f"ok find {len(res.rows)} plan {res.plan}"] + [
            f"  {_key(k)} = {render(d)}" for k, d in res.rows]
    if t is CreateIndex:
        return [f"ok create index {'.'.join(cmd.segs)} entries {db.create_index(cmd.segs)}"]
    if t is DropIndex:
        return [f"ok drop index {'.'.join(cmd.segs)} pages {db.drop_index(cmd.segs)}"]
    raise AssertionError(cmd)


def run_line(db: Database, number: int, line: str) -> list[str]:
    """Run one command line; the result is the block of ``results.txt`` for it."""
    try:
        lines = execute(db, parse_command(line))
    except TesseraError as e:
        lines = [f"error {e.kind}"]
    except RecursionError:
        lines = ["error syntax"]
    lines[0] = f"[{number}] {lines[0]}"
    return lines


def split_lines(text: str) -> list[str]:
    """Command lines of a script: LF terminates a line, it does not start another."""
    if not text:
        return []
    lines = text.split("\n")
    if text.endswith("\n"):
        lines.pop()
    return lines


def run_script(db: Database, text: str) -> str:
    """Run a whole script; returns the text of ``results.txt``.

    An explicit transaction still open at the end is rolled back (SPEC §2.3).
    """
    out: list[str] = []
    for number, line in enumerate(split_lines(text), 1):
        out.extend(run_line(db, number, line))
    if db.in_transaction:
        db.rollback()
    return "".join(line + "\n" for line in out)
