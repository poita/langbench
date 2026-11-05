#!/usr/bin/env python3
"""Kiln: the buildsys reference implementation.

Usage: main.py <input directory> <output directory>
"""
import os
import re
import sys
import threading

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from kiln_vfs import (load_workspace, dump_workspace, is_generated,
                      STATE_PATH, Workspace)      # noqa: E402
from kbl_lex import physical_lines                # noqa: E402
from kiln_engine import run_build                 # noqa: E402

WORD_SPLIT = re.compile(b"[ \t]+")


class SessionStep(object):
    __slots__ = ("kind", "targets", "workers", "path", "content")

    def __init__(self, kind):
        self.kind = kind
        self.targets = []
        self.workers = 1
        self.path = None
        self.content = b""


def parse_session(src):
    """Parse ``session.txt`` into a list of session steps."""
    lines = physical_lines(src)
    steps = []
    i = 0
    n = len(lines)
    while i < n:
        raw = lines[i]
        trimmed = raw.strip(b" \t")
        if not trimmed or trimmed[:1] == b"#":
            i += 1
            continue
        words = WORD_SPLIT.split(trimmed)
        head = words[0]
        i += 1
        if head == b"build":
            step = SessionStep(b"build")
            rest = words[1:]
            if len(rest) >= 2 and rest[-2] == b"-j":
                step.workers = int(rest[-1])
                rest = rest[:-2]
            step.targets = rest
            steps.append(step)
        elif head in (b"create", b"edit"):
            step = SessionStep(head)
            step.path = words[1]
            body = []
            while i < n and lines[i] != b"---":
                body.append(lines[i])
                i += 1
            i += 1
            step.content = b"".join(l + b"\n" for l in body)
            steps.append(step)
        elif head in (b"delete", b"touch"):
            step = SessionStep(head)
            step.path = words[1]
            steps.append(step)
        elif head == b"clean":
            steps.append(SessionStep(b"clean"))
        else:
            raise SystemExit("bad session line: %r" % raw)
    return steps


def render_events(events, out):
    for e in events:
        if e.kind == b"hit":
            out.append(b"  hit " + b"%d" % e.start + b" " + e.target)
        else:
            out.append(b"  " + e.kind + b" " + b"%d" % e.start + b" " +
                       b"%d" % e.end + b" w" + b"%d" % e.worker + b" " +
                       e.target + b" " + e.command)


def run_session(ws, steps):
    out = []
    for n, step in enumerate(steps, 1):
        prefix = b"step " + b"%d" % n + b": "
        if step.kind == b"build":
            if step.targets:
                shown = b" ".join(step.targets)
            else:
                shown = b"(default)"
            out.append(prefix + b"build " + shown + b" -j " +
                       b"%d" % step.workers)
            events, result = run_build(ws, step.targets, step.workers)
            render_events(events, out)
            if result[0] == "ok":
                out.append(b"  ok ran=" + b"%d" % result[1] + b" hit=" +
                           b"%d" % result[2] + b" time=" + b"%d" % result[3])
            else:
                out.append(b"  error " + result[1].render())
        elif step.kind in (b"create", b"edit"):
            out.append(prefix + step.kind + b" " + step.path)
            ws.write(step.path, step.content)
            out.append(b"  ok size=" + b"%d" % len(step.content))
        elif step.kind == b"delete":
            out.append(prefix + b"delete " + step.path)
            ws.remove(step.path)
            out.append(b"  ok")
        elif step.kind == b"touch":
            out.append(prefix + b"touch " + step.path)
            ws.touch(step.path)
            out.append(b"  ok")
        else:
            out.append(prefix + b"clean")
            doomed = sorted(p for p in ws.files
                            if is_generated(p) or p == STATE_PATH)
            for p in doomed:
                out.append(b"  remove " + p)
                ws.remove(p)
            out.append(b"  ok removed=" + b"%d" % len(doomed))
    if not out:
        return b""
    return b"\n".join(out) + b"\n"


def main(argv):
    if len(argv) != 3:
        sys.stderr.write("usage: main.py <input dir> <output dir>\n")
        return 2
    indir, outdir = argv[1], argv[2]
    os.makedirs(outdir, exist_ok=True)
    session_path = os.path.join(indir, "session.txt")
    with open(session_path, "rb") as f:
        session_src = f.read()
    ws = load_workspace(indir)
    steps = parse_session(session_src)
    log = run_session(ws, steps)
    with open(os.path.join(outdir, "log.txt"), "wb") as f:
        f.write(log)
    dump_workspace(ws, outdir)
    return 0


def _entry():
    global _STATUS
    _STATUS = main(sys.argv)


if __name__ == "__main__":
    sys.setrecursionlimit(200000)
    threading.stack_size(256 * 1024 * 1024)
    _STATUS = 0
    t = threading.Thread(target=_entry)
    t.start()
    t.join()
    sys.exit(_STATUS)
