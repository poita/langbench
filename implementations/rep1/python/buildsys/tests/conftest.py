"""Shared helpers for the Kiln test suite."""

from __future__ import annotations

import pytest

from kiln import VirtualFS, run_session


def make_fs(files: dict[str, str | bytes]) -> VirtualFS:
    fs = VirtualFS()
    for path, content in files.items():
        fs.write(path.encode(), content.encode() if isinstance(content, str) else content)
    return fs


@pytest.fixture
def session():
    """``session(files, script) -> (log_text, fs)``: run a session in memory."""

    def run(files: dict[str, str | bytes], script: str):
        fs = make_fs(files)
        log = run_session(fs, script.encode())
        return log.decode(), fs

    return run
