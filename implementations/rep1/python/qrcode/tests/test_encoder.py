import pytest

from qrcode import DataTooLongError, ErrorCorrection, QrCode, encode_bytes, encode_text
from qrcode.encoder import add_ecc_and_interleave

EXAMPLE_1 = """\
#######...#.#.#######
#.....#.###...#.....#
#.###.#...#.#.#.###.#
#.###.#...#.#.#.###.#
#.###.#.#.###.#.###.#
#.....#..###..#.....#
#######.#.#.#.#######
.....................
#.#.#.#..#..#...#..#.
.####...#..#....#...#
...#######.#..#.##...
####.#.##..###.#.###.
.#..####.#.#..###.#.#
........#.#...#...#.#
#######.....#..#.##..
#.....#..##...##.#...
#.###.#.##..#.#######
#.###.#...##.#.#...#.
#.###.#.####.###.#..#
#.....#....###...#.##
#######.##.#.###....#
"""

EXAMPLE_2 = """\
#######.##..#.#######
#.....#..#..#.#.....#
#.###.#.#.#.#.#.###.#
#.###.#.#..#..#.###.#
#.###.#.###...#.###.#
#.....#.......#.....#
#######.#.#.#.#######
.........##..........
####..#.#.#..#..###.#
####...##...#..#.##..
....######..#####..#.
##..#..##.#.##...#.#.
#..#..##..##.#..#....
........##...#.#....#
#######..##..##.#.##.
#.....#....####...#.#
#.###.#..#.#..#.....#
#.###.#.#....#..#.##.
#.###.#.#..#.#..#.#..
#.....#.##.##.#.##.##
#######.##.##..#...#.
"""

EXAMPLE_3 = """\
#######.####..#######
#.....#..##.#.#.....#
#.###.#.#.#...#.###.#
#.###.#..#....#.###.#
#.###.#.#.#...#.###.#
#.....#..##...#.....#
#######.#.#.#.#######
........#.#..........
.....##...#.#.#.#.#.#
.#####.......#..#.#.#
.####.#####..#..##.##
.##.##.#..#.#...#....
#..#.###.#....#..#.#.
........#.####......#
#######..##..###.###.
#.....#.#..##.##.##..
#.###.#.....##..#..#.
#.###.#..##.##..##...
#.###.#.........#####
#.....#...#.#.#..##..
#######...#.#.#.#..#.
"""


def test_example_1_fixed_mask():
    qr = encode_text("HELLO WORLD", "M", 0)
    assert (qr.version, qr.mask) == (1, 0)
    assert qr.to_text() == EXAMPLE_1


def test_example_1_auto_picks_mask_0():
    qr = encode_text("HELLO WORLD", ErrorCorrection.M)
    assert (qr.version, qr.mask) == (1, 0)
    assert qr.to_text() == EXAMPLE_1


def test_example_2_numeric_auto():
    qr = encode_text("01234567", "L")
    assert (qr.version, qr.mask) == (1, 3)
    assert qr.to_text() == EXAMPLE_2


def test_example_3_utf8():
    qr = encode_text("héllo", "H", 5)
    assert (qr.version, qr.mask) == (1, 5)
    assert qr.to_text() == EXAMPLE_3


def test_result_type_and_accessors():
    qr = encode_text("HELLO WORLD", "M", 0)
    assert isinstance(qr, QrCode)
    assert qr.size == 21
    assert qr.get_module(0, 0) is True
    assert qr.get_module(7, 0) is False
    assert qr.get_module(-1, 0) is False and qr.get_module(21, 21) is False
    m = qr.to_matrix()
    assert len(m) == 21 and all(len(r) == 21 for r in m)
    assert qr.to_lines("X", " ")[0] == "XXXXXXX   X X XXXXXXX"


def test_function_modules_present():
    from qrcode.layout import version_bits

    for v, text in [(2, "a" * 30), (7, "a" * 150), (40, "a" * 2900)]:
        qr = encode_text(text, "L")
        assert qr.version == v
        n = qr.size
        assert qr.get_module(8, n - 8)  # dark module
        assert qr.get_module(3, 3) and not qr.get_module(1, 1)  # finder
        assert qr.get_module(n - 4, 3) and qr.get_module(3, n - 4)
        if v >= 7:
            bits = version_bits(v)
            for i in range(18):
                b = bool((bits >> i) & 1)
                assert qr.get_module(n - 11 + i % 3, i // 3) == b
                assert qr.get_module(i // 3, n - 11 + i % 3) == b


def test_version_selection_by_mode():
    assert encode_text("9" * 41, "L").version == 1
    assert encode_text("9" * 42, "L").version == 2
    assert encode_text("a" * 17, "L").version == 1
    assert encode_text("a" * 18, "L").version == 2


def test_max_capacity_v40():
    assert encode_text("1" * 7089, "L", 0).version == 40
    assert encode_text("a" * 2953, "L", 0).version == 40
    assert encode_text("1" * 3057, "H", 0).version == 40


def test_too_long():
    with pytest.raises(DataTooLongError):
        encode_text("1" * 7090, "L")
    with pytest.raises(DataTooLongError):
        encode_text("a" * 1274, "H")


def test_invalid_arguments():
    with pytest.raises(ValueError):
        encode_text("x", "Z")
    with pytest.raises(ValueError):
        encode_text("x", "L", 8)


def test_encode_bytes_equals_encode_text():
    assert encode_bytes("héllo".encode(), "M", 2) == encode_text("héllo", "M", 2)


def test_interleave_structure():
    # v5-Q: 4 blocks (2 short with 15 data, 2 long with 16), 18 ECC each.
    data = bytes(range(62))
    out = add_ecc_and_interleave(data, 5, ErrorCorrection.Q)
    assert len(out) == 134
    # first four codewords are the first byte of each block
    assert list(out[:4]) == [0, 15, 30, 46]
    # last data position exists only for the two long blocks
    assert list(out[60:62]) == [45, 61]
