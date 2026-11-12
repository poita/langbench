import pytest

from tomlcodec import loads, to_tagged_json


@pytest.fixture
def decode():
    """Decode a TOML string straight to its tagged-JSON text."""
    return lambda doc: to_tagged_json(loads(doc))
