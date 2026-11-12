import pytest

from minisql import Database, format_results


@pytest.fixture
def db():
    return Database()


@pytest.fixture
def run():
    """Run a script on a fresh database and return the CLI-style output."""

    def _run(script: str) -> str:
        return format_results(Database().execute(script))

    return _run
