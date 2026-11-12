from qrcode import reedsolomon as rs


def test_multiply_basics():
    assert rs.gf_multiply(0, 7) == 0
    assert rs.gf_multiply(1, 0xAB) == 0xAB
    assert rs.gf_multiply(2, 0x80) == 0x1D  # 2^8 reduces to 0x1D


def test_generator_degree_7():
    assert rs.generator_polynomial(7) == [127, 122, 154, 164, 11, 68, 117]


def test_spec_example_ecc():
    data = bytes([32, 91, 11, 120, 209, 114, 220, 77, 67, 64, 236, 17, 236, 17, 236, 17])
    assert list(rs.remainder(data, 10)) == [196, 35, 39, 119, 235, 215, 231, 226, 93, 23]


def test_remainder_matches_naive_division():
    data = bytes(range(1, 40))
    degree = 13
    gen = [1] + rs.generator_polynomial(degree)
    buf = list(data) + [0] * degree
    for i in range(len(data)):
        f = buf[i]
        if f:
            for j, g in enumerate(gen):
                buf[i + j] ^= rs.gf_multiply(g, f)
    assert list(rs.remainder(data, degree)) == buf[len(data):]
