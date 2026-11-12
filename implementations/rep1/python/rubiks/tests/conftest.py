import pytest

from rubiks import Solver


@pytest.fixture(scope="session")
def solver():
    """One solver (and so one set of tables) shared by the whole test run."""
    s = Solver()
    s.build_all()
    return s
