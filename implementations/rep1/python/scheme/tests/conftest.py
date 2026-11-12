import pytest

from scheme_interp import run_program


@pytest.fixture
def run():
    """Run a program and return its output."""
    return run_program
