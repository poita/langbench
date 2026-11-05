module tests.test_matrix;

import qrcode.matrix;
import qrcode.tables;

unittest // BCH words
{
    assert(versionBits(7) == 0x07C94);
    assert(versionBits(40) == 0x28C69);
    assert(formatWord(Ecl.M, 0) == 0x5412);
    assert(formatWord(Ecl.H, 7) == 0x083B);
}

unittest // function pattern counts: data modules == raw modules for every version
{
    foreach (ver; minVersion .. maxVersion + 1)
    {
        auto g = buildFunctionPatterns(ver, Ecl.L);
        size_t free = 0;
        foreach (f; g.isFunction)
            free += f == 0;
        assert(free == rawDataModules(ver), "free module count mismatch");
    }
}

unittest // fixed landmarks
{
    auto g = buildFunctionPatterns(2, Ecl.L);
    const n = g.size;
    bool dark(int x, int y) { return g.modules[y * n + x] != 0; }
    assert(dark(0, 0) && dark(6, 6) && !dark(1, 1) && dark(3, 3));
    assert(!dark(7, 0) && !dark(7, 7)); // separator
    assert(dark(8, n - 8));
    assert(dark(18, 18) && !dark(17, 18) && dark(16, 16)); // alignment pattern
    assert(dark(8, 6) && !dark(9, 6) && dark(10, 6)); // timing
}

unittest // placement fills exactly the free modules
{
    auto g = buildFunctionPatterns(1, Ecl.L);
    auto cw = new ubyte[26];
    cw[] = 0xFF;
    placeCodewords(g, cw);
    size_t darkData = 0;
    foreach (i, f; g.isFunction)
        if (!f)
            darkData += g.modules[i];
    assert(darkData == 26 * 8 - 0); // 208 free modules, all set
}

unittest // mask conditions
{
    assert(maskCondition(0, 1, 1) && !maskCondition(0, 1, 0));
    assert(maskCondition(1, 5, 2) && !maskCondition(1, 5, 3));
    assert(maskCondition(2, 3, 9) && !maskCondition(2, 4, 9));
    assert(maskCondition(4, 0, 0) && !maskCondition(4, 3, 0));
}

unittest // rendering leaves the base untouched and masks only data modules
{
    auto g = buildFunctionPatterns(1, Ecl.M);
    auto scratch = new ubyte[g.modules.length];
    auto copy = g.modules.dup;
    renderMask(g, scratch, Ecl.M, 1);
    assert(g.modules == copy);
    // finder pattern unchanged
    assert(scratch[0] == 1 && scratch[1 * g.size + 1] == 0);
}
