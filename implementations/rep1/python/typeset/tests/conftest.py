import os

import pytest

HERE = os.path.dirname(os.path.abspath(__file__))


@pytest.fixture(scope="session")
def data_dir() -> str:
    """Directory with ``faces/`` and ``hyphen/`` (a copy of the shipped data)."""
    return os.path.join(HERE, "data")


SMALL_CFG = """\
page-width   = 200pt
page-height  = 120pt
margin-top   = 20pt
margin-bottom = 20pt
margin-left  = 20pt
margin-right = 20pt
"""


@pytest.fixture
def small_cfg() -> str:
    return SMALL_CFG
