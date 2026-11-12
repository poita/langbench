from chip8 import Display


def test_blank():
    rows = Display().rows()
    assert len(rows) == 32 and all(r == "." * 64 for r in rows)


def test_xor_and_collision():
    d = Display()
    mem = bytearray(4096)
    mem[0] = 0x80
    assert d.draw_sprite(mem, 0, 3, 4, 1) == 0
    assert d.get(3, 4) == 1
    assert d.draw_sprite(mem, 0, 3, 4, 1) == 1
    assert d.get(3, 4) == 0


def test_wrap():
    d = Display()
    mem = bytearray([0xC0, 0xC0])
    d.draw_sprite(mem, 0, 63 + 64, 31 + 32, 2)
    assert {(x, y) for y in range(32) for x in range(64) if d.get(x, y)} == {
        (63, 31), (0, 31), (63, 0), (0, 0)
    }


def test_zero_rows_draws_nothing():
    d = Display()
    assert d.draw_sprite(bytearray([0xFF]), 0, 0, 0, 0) == 0
    assert not any(d.pixels)


def test_clear():
    d = Display()
    d.draw_sprite(bytearray([0xFF]), 0, 0, 0, 1)
    d.clear()
    assert not any(d.pixels)
