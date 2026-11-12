"""Processing of a ``render.txt`` job list."""

from __future__ import annotations

import os
import sys

from .render import render_to_ppm

__all__ = ["parse_render_list", "render_directory"]


def parse_render_list(text: str) -> list[tuple[str, int, int]]:
    """Parse the contents of ``render.txt`` into ``(name, width, height)``."""
    jobs: list[tuple[str, int, int]] = []
    for line in text.split("\n"):
        line = line.rstrip("\r")
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        fields = stripped.split()
        if len(fields) != 3:
            raise ValueError(f"bad render.txt line: {line!r}")
        jobs.append((fields[0], int(fields[1]), int(fields[2])))
    return jobs


def render_directory(input_dir: str, output_dir: str) -> int:
    """Render every file listed in ``<input_dir>/render.txt``.

    Returns the number of files that could not be rendered (after reporting
    each on stderr).
    """
    with open(os.path.join(input_dir, "render.txt"), encoding="utf-8") as fh:
        jobs = parse_render_list(fh.read())
    os.makedirs(output_dir, exist_ok=True)
    failures = 0
    for name, width, height in jobs:
        try:
            with open(os.path.join(input_dir, name), encoding="utf-8", errors="replace") as fh:
                svg = fh.read()
            data = render_to_ppm(svg, width, height)
            stem = name[:-4] if name.endswith(".svg") else name
            with open(os.path.join(output_dir, stem + ".ppm"), "wb") as out:
                out.write(data)
        except OSError as exc:
            print(f"svgraster: {name}: {exc}", file=sys.stderr)
            failures += 1
    return failures
