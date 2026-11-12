"""The 64x32 monochrome display."""

from .constants import ADDRESS_MASK, DISPLAY_HEIGHT, DISPLAY_WIDTH

_W_MASK = DISPLAY_WIDTH - 1
_H_MASK = DISPLAY_HEIGHT - 1


class Display:
    """A 64x32 frame buffer of 1-bit pixels, stored one byte per pixel."""

    __slots__ = ("pixels",)

    def __init__(self) -> None:
        self.pixels = bytearray(DISPLAY_WIDTH * DISPLAY_HEIGHT)

    def clear(self) -> None:
        """Turn every pixel off."""
        self.pixels[:] = bytes(DISPLAY_WIDTH * DISPLAY_HEIGHT)

    def get(self, x: int, y: int) -> int:
        """Return pixel (``x``, ``y``) as 0 or 1."""
        return self.pixels[y * DISPLAY_WIDTH + x]

    def draw_sprite(self, memory, i: int, x: int, y: int, rows: int) -> int:
        """XOR a sprite of ``rows`` bytes read from ``memory[i...]`` onto the screen.

        The origin ``(x, y)`` is reduced modulo the screen size and pixels
        wrap around the edges. Returns 1 if any lit pixel was turned off.
        """
        pixels = self.pixels
        sx = x & _W_MASK
        sy = y & _H_MASK
        collision = 0
        for row in range(rows):
            byte = memory[(i + row) & ADDRESS_MASK]
            if not byte:
                continue
            base = ((sy + row) & _H_MASK) * DISPLAY_WIDTH
            for bit in range(8):
                if byte & (0x80 >> bit):
                    idx = base + ((sx + bit) & _W_MASK)
                    if pixels[idx]:
                        collision = 1
                        pixels[idx] = 0
                    else:
                        pixels[idx] = 1
        return collision

    def rows(self) -> list[str]:
        """Render the screen as 32 strings of 64 characters (``#`` lit, ``.`` unlit)."""
        text = self.pixels.translate(_TRANSLATE).decode("ascii")
        return [
            text[r * DISPLAY_WIDTH : (r + 1) * DISPLAY_WIDTH]
            for r in range(DISPLAY_HEIGHT)
        ]


_TRANSLATE = bytes([ord(".")] + [ord("#")] * 255)
