"""The :class:`QrCode` result type."""

from __future__ import annotations

from dataclasses import dataclass

from .tables import ErrorCorrection


@dataclass(frozen=True)
class QrCode:
    """An encoded QR Code Model 2 symbol (without quiet zone).

    Attributes:
        version: Symbol version, 1..40.
        ecl: Error correction level.
        mask: Mask pattern number used, 0..7.
        size: Side length in modules, ``4 * version + 17``.
    """

    version: int
    ecl: ErrorCorrection
    mask: int
    size: int
    _rows: tuple[int, ...]  # bit (size - 1 - x) of row y is module (x, y)

    def get_module(self, x: int, y: int) -> bool:
        """True if the module at column ``x``, row ``y`` is dark.

        Coordinates outside the symbol are light.
        """
        if 0 <= x < self.size and 0 <= y < self.size:
            return bool((self._rows[y] >> (self.size - 1 - x)) & 1)
        return False

    def to_matrix(self) -> list[list[bool]]:
        """The symbol as ``size`` rows of booleans (True = dark)."""
        n = self.size
        return [[bool((r >> (n - 1 - x)) & 1) for x in range(n)] for r in self._rows]

    def to_lines(self, dark: str = "#", light: str = ".") -> list[str]:
        """One string per row, using ``dark`` / ``light`` characters."""
        table = {ord("1"): dark, ord("0"): light}
        fmt = f"0{self.size}b"
        return [format(r, fmt).translate(table) for r in self._rows]

    def to_text(self, dark: str = "#", light: str = ".") -> str:
        """The symbol as newline-terminated rows."""
        return "".join(line + "\n" for line in self.to_lines(dark, light))
