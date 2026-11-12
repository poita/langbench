"""Session scripts: parsing, execution and the log.

A session is a scripted sequence of builds and workspace mutations.
:func:`run_session` executes one against a :class:`~kiln.vfs.VirtualFS` and
returns the text of ``log.txt``.
"""

from __future__ import annotations

import os
import re
from dataclasses import dataclass

from .build import BuildResult, build
from .vfs import VirtualFS

__all__ = ["SessionStep", "parse_session", "run_session", "run_session_dir"]

_WORDS = re.compile(rb"[ \t]+")


@dataclass(slots=True)
class SessionStep:
    """One session step: ``kind`` is build/create/edit/delete/touch/clean."""

    kind: bytes
    path: bytes = b""
    targets: tuple[bytes, ...] = ()
    jobs: int = 1
    content: bytes = b""


def parse_session(text: bytes) -> list[SessionStep]:
    """Parse ``session.txt`` into steps."""
    lines = text.split(b"\n")
    steps: list[SessionStep] = []
    i = 0
    while i < len(lines):
        raw = lines[i]
        i += 1
        line = raw.strip(b" \t")
        if not line or line.startswith(b"#"):
            continue
        words = _WORDS.split(line)
        kind = words[0]
        if kind == b"build":
            args = words[1:]
            jobs = 1
            if len(args) >= 2 and args[-2] == b"-j":
                jobs = int(args[-1])
                args = args[:-2]
            steps.append(SessionStep(kind, targets=tuple(args), jobs=jobs))
        elif kind in (b"create", b"edit"):
            body: list[bytes] = []
            while i < len(lines) and lines[i] != b"---":
                body.append(lines[i])
                i += 1
            i += 1  # the terminator
            content = b"".join(l + b"\n" for l in body)
            steps.append(SessionStep(kind, path=words[1], content=content))
        elif kind in (b"delete", b"touch"):
            steps.append(SessionStep(kind, path=words[1]))
        elif kind == b"clean":
            steps.append(SessionStep(kind))
        else:
            raise ValueError("unknown session step: %r" % raw)
    return steps


def _format_build(result: BuildResult) -> list[bytes]:
    lines: list[bytes] = []
    for e in result.events:
        if e.kind == "hit":
            lines.append(b"  hit %d %b" % (e.start, e.target))
        else:
            lines.append(
                b"  %b %d %d w%d %b %b"
                % (e.kind.encode(), e.start, e.end, e.worker, e.target, e.command)
            )
    if result.error is not None:
        lines.append(b"  error " + result.error.render())
    else:
        lines.append(b"  ok ran=%d hit=%d time=%d" % (result.ran, result.hits, result.time))
    return lines


def run_session(fs: VirtualFS, session: bytes | list[SessionStep]) -> bytes:
    """Execute a session against ``fs`` (mutating it); return the log text."""
    steps = parse_session(session) if isinstance(session, bytes) else session
    out: list[bytes] = []
    for n, step in enumerate(steps, 1):
        kind = step.kind
        if kind == b"build":
            targets = b" ".join(step.targets) if step.targets else b"(default)"
            out.append(b"step %d: build %b -j %d" % (n, targets, step.jobs))
            out.extend(_format_build(build(fs, step.targets, step.jobs)))
        elif kind in (b"create", b"edit"):
            out.append(b"step %d: %b %b" % (n, kind, step.path))
            fs.write(step.path, step.content)
            out.append(b"  ok size=%d" % len(step.content))
        elif kind == b"delete":
            out.append(b"step %d: delete %b" % (n, step.path))
            fs.delete(step.path)
            out.append(b"  ok")
        elif kind == b"touch":
            out.append(b"step %d: touch %b" % (n, step.path))
            fs.touch(step.path)
            out.append(b"  ok")
        else:  # clean
            out.append(b"step %d: clean" % n)
            removed = fs.remove_generated()
            out.extend(b"  remove " + p for p in removed)
            out.append(b"  ok removed=%d" % len(removed))
    return b"".join(line + b"\n" for line in out)


def run_session_dir(input_dir: str | os.PathLike[str], output_dir: str | os.PathLike[str]) -> None:
    """The command-line contract: read ``input_dir``, write ``log.txt`` and ``workspace/``."""
    with open(os.path.join(input_dir, "session.txt"), "rb") as fh:
        session = fh.read()
    fs = VirtualFS.from_directory(input_dir)
    log = run_session(fs, session)
    os.makedirs(output_dir, exist_ok=True)
    with open(os.path.join(output_dir, "log.txt"), "wb") as fh:
        fh.write(log)
    fs.write_to_directory(os.path.join(output_dir, "workspace"))
