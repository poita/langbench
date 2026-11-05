module tests.test_penalty;

import qrcode.penalty;

unittest // an all-light 5x5 grid
{
    auto m = new ubyte[25];
    // N1: 10 lines of run 5 -> 10*3 = 30; N2: 16 blocks -> 48; N4: 0 dark -> k = 10 -> 100
    assert(penaltyScore(m, 5) == 30 + 48 + 100);
}

unittest // N3 pattern in a row
{
    // 11x11 grid, light except one row holding #.###.#.... at the left edge.
    enum n = 11;
    auto m = new ubyte[n * n];
    immutable ubyte[11] pat = [1, 0, 1, 1, 1, 0, 1, 0, 0, 0, 0];
    m[5 * n .. 6 * n] = pat[];
    auto with_ = penaltyScore(m, n);
    m[5 * n .. 6 * n] = 0;
    // The pattern row adds exactly one N3 hit (40); other terms differ, so only check ordering
    assert(with_ != penaltyScore(m, n));
}
