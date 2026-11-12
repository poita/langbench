import pytest

from langvm import run_source


def main_module(body: str, extra: str = "") -> str:
    """A one-module program whose ``main`` body is ``body``."""
    return f"@module main\n{extra}\nfn main() {{\n{body}\n}}\n"


@pytest.fixture
def run():
    """Run a full module stream; return its stdout text."""

    def _run(src: str) -> str:
        return run_source(src).output

    return _run


@pytest.fixture
def run_main(run):
    """Run ``body`` as the body of ``main`` (with optional extra items)."""

    def _run(body: str, extra: str = "") -> str:
        return run(main_module(body, extra))

    return _run
