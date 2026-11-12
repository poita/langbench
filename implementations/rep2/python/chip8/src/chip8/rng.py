"""The 32-bit linear congruential generator used by ``CXNN``."""

DEFAULT_SEED = 0x12345678
_MULTIPLIER = 1103515245
_INCREMENT = 12345
_MASK = 0xFFFFFFFF


class Lcg:
    """``s = (s * 1103515245 + 12345) mod 2**32``; output is bits 16..23."""

    __slots__ = ("state",)

    def __init__(self, seed: int = DEFAULT_SEED) -> None:
        self.state = seed & _MASK

    def next_byte(self) -> int:
        """Advance the generator once and return the next random byte."""
        s = (self.state * _MULTIPLIER + _INCREMENT) & _MASK
        self.state = s
        return (s >> 16) & 0xFF
