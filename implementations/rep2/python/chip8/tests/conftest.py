import pytest

from chip8 import Machine


@pytest.fixture
def make_machine():
    """Build a machine from a list of 16-bit opcodes."""

    def build(*opcodes: int) -> Machine:
        return Machine(b"".join(op.to_bytes(2, "big") for op in opcodes))

    return build
