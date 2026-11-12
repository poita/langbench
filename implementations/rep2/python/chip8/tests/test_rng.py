from chip8 import Lcg


def test_spec_sequence():
    rng = Lcg()
    assert [rng.next_byte() for _ in range(3)] == [0x71, 0x47, 0x1D]


def test_states():
    rng = Lcg()
    states = []
    for _ in range(3):
        rng.next_byte()
        states.append(rng.state)
    assert states == [0x0B719151, 0x6F47BDB6, 0x2E1D6AB7]
