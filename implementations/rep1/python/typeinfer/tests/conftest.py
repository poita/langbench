import pytest

from typeinfer import infer_program, run_deep


@pytest.fixture
def check():
    """check(source) -> list of output lines, as the CLI prints them."""

    def run(source: str) -> list[str]:
        return run_deep(lambda: [r.render() for r in infer_program(source)])

    return run
