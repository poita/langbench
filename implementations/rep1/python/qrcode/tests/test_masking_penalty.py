import random

from qrcode import encode_text
from qrcode.layout import format_bits, version_bits
from qrcode.masking import NUM_MASKS, mask_condition, mask_rows
from qrcode.penalty import penalty


def test_mask_rows_match_formula():
    for size in (21, 25, 57, 177):
        for m in range(NUM_MASKS):
            rows = mask_rows(size, m)
            for y in range(0, size, 5):
                for x in range(size):
                    assert bool((rows[y] >> (size - 1 - x)) & 1) == mask_condition(m, x, y)


def test_format_bits_known():
    assert format_bits(0, 0) == 0b101010000010010  # M, mask 0
    assert format_bits(1, 0) == 0b111011111000100  # L, mask 0


def test_version_bits_known():
    assert version_bits(7) == 0b000111110010010100
    assert version_bits(40) == 0b101000110001101001


def _naive_penalty(qr):
    n = qr.size
    g = qr.to_matrix()
    total = 0
    lines = [row for row in g] + [[g[y][x] for y in range(n)] for x in range(n)]
    for line in lines:
        run = 1
        for i in range(1, n + 1):
            if i < n and line[i] == line[i - 1]:
                run += 1
            else:
                if run >= 5:
                    total += 3 + run - 5
                run = 1
        for i in range(n - 10):
            w = line[i : i + 11]
            if w == [1, 0, 1, 1, 1, 0, 1, 0, 0, 0, 0] or w == [0, 0, 0, 0, 1, 0, 1, 1, 1, 0, 1]:
                total += 40
    for y in range(n - 1):
        for x in range(n - 1):
            if g[y][x] == g[y][x + 1] == g[y + 1][x] == g[y + 1][x + 1]:
                total += 3
    dark = sum(map(sum, g))
    total += 10 * (abs(20 * dark - 10 * n * n) // (n * n))
    return total


def test_penalty_matches_naive_implementation():
    rng = random.Random(1)
    for text in ["HELLO WORLD", "0123456789" * 20, "x" * 300, "".join(chr(rng.randrange(97, 123)) for _ in range(900))]:
        for m in (0, 3, 6):
            qr = encode_text(text, "M", m)
            assert penalty(tuple(int("".join("1" if b else "0" for b in r), 2) for r in qr.to_matrix()), qr.size) == _naive_penalty(qr)


def test_spec_penalties_hello_world():
    scores = []
    for m in range(8):
        qr = encode_text("HELLO WORLD", "M", m)
        rows = [int(line.translate({35: "1", 46: "0"}), 2) for line in qr.to_lines()]
        scores.append(penalty(rows, qr.size))
    assert scores == [311, 406, 442, 463, 367, 528, 395, 445]
