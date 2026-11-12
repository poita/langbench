"""Session scripts and the session log.

A session is a scripted sequence of builds and workspace mutations
(``session.txt``).  :func:`run_session` executes one against a
:class:`~kiln.vfs.VirtualFS` and returns the text of ``log.txt``.
"""

from __future__ import annotations

import re
from dataclasses import dataclass

from .build import Builder, BuildResult
from .paths import STATE_FILE, is_generated
from .vfs import VirtualFS

_BLANKS = b" \t"
_WORD_SPLIT = re.compile(rb"[ \t]+")


@dataclass(slots=True)
class Build:
    targets: list[bytes]
    workers: int = 1


@dataclass(slots=True)
class Write:
    """``create`` or ``edit``: replace a file's content."""

    verb: bytes
    path: bytes
    content: bytes


@dataclass(slots=True)
class Delete:
    path: bytes


@dataclass(slots=True)
class Touch:
    path: bytes


@dataclass(slots=True)
class Clean:
    pass


SessionStep = Build | Write | Delete | Touch | Clean


def parse_session(text: bytes) -> list[SessionStep]:
    """Parse ``session.txt`` into steps."""
    lines = text.split(b"\n")
    steps: list[SessionStep] = []
    i = 0
    while i < len(lines):
        line = lines[i].strip(_BLANKS)
        i += 1
        if not line or line[:1] == b"#":
            continue
        words = _WORD_SPLIT.split(line)
        verb = words[0]
        if verb == b"build":
            args = words[1:]
            workers = 1
            if len(words) >= 3 and words[-2] == b"-j":
                workers = int(words[-1])
                args = words[1:-2]
            steps.append(Build(args, workers))
        elif verb == b"create" or verb == b"edit":
            body: list[bytes] = []
            while i < len(lines) and lines[i] != b"---":
                body.append(lines[i])
                i += 1
            i += 1  # the terminator
            steps.append(Write(verb, words[1], b"".join([ln + b"\n" for ln in body])))
        elif verb == b"delete":
            steps.append(Delete(words[1]))
        elif verb == b"touch":
            steps.append(Touch(words[1]))
        elif verb == b"clean":
            steps.append(Clean())
        else:
            raise ValueError(f"bad session line: {line!r}")
    return steps


def _build_header(step: Build) -> bytes:
    targets = b" ".join(step.targets) if step.targets else b"(default)"
    return b"build " + targets + b" -j " + str(step.workers).encode()


def _format_build(result: BuildResult) -> list[bytes]:
    lines = []
    for ev in result.events:
        if ev.kind == "hit":
            lines.append(b"  hit %d %s" % (ev.start, ev.target))
        else:
            lines.append(
                b"  %s %d %d w%d %s %s"
                % (ev.kind.encode(), ev.start, ev.end, ev.worker, ev.target, ev.command)
            )
    if result.error is not None:
        lines.append(b"  error " + result.error.render())
    else:
        lines.append(b"  ok ran=%d hit=%d time=%d" % (result.ran, result.hits, result.time))
    return lines


def run_session(vfs: VirtualFS, text: bytes) -> bytes:
    """Run the session script *text* against *vfs*; returns the log bytes."""
    builder = Builder(vfs)
    log: list[bytes] = []
    for n, step in enumerate(parse_session(text), 1):
        prefix = b"step %d: " % n
        if isinstance(step, Build):
            log.append(prefix + _build_header(step))
            log += _format_build(builder.build(step.targets, step.workers))
        elif isinstance(step, Write):
            log.append(prefix + step.verb + b" " + step.path)
            vfs.write(step.path, step.content)
            log.append(b"  ok size=%d" % len(step.content))
        elif isinstance(step, Delete):
            log.append(prefix + b"delete " + step.path)
            vfs.delete(step.path)
            log.append(b"  ok")
        elif isinstance(step, Touch):
            log.append(prefix + b"touch " + step.path)
            if step.path in vfs:
                vfs.touch(step.path)
            log.append(b"  ok")
        else:
            log.append(prefix + b"clean")
            doomed = sorted(p for p in vfs.paths() if is_generated(p) or p == STATE_FILE)
            for path in doomed:
                vfs.delete(path)
                log.append(b"  remove " + path)
            log.append(b"  ok removed=%d" % len(doomed))
    return b"".join([ln + b"\n" for ln in log])
