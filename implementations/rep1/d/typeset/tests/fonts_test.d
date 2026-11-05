module tests.fonts_test;

import typeset.fonts;
import tests.support;

unittest // face resolution table
{
    assert(faceIndex(Family.serif, false, false) == 0);
    assert(faceIndex(Family.serif, true, true) == 3);
    assert(faceIndex(Family.sans, true, false) == 5);
    assert(faceIndex(Family.mono, true, true) == monoFace);
    assert(faceNames[faceIndex(Family.sans, false, true)] == "sans-italic");
}

unittest // metric parsing and measurement with a single scale
{
    auto f = parseFace(syntheticFace("serif"));
    assert(f.ascent == 800 && f.descent == 200 && f.space == 250);
    assert(f.adv('a') == 500 && f.adv(0x4E2D) == 500); // beyond the table: default
    assert(f.kern('A', 'V') == -100 && f.kern('V', 'A') == 0);
    uint[] av = ['A', 'V'];
    assert(f.units(av) == 900);
    assert(f.width(av, 10000) == 9000);
}

unittest // comments and blank lines are ignored
{
    auto f = parseFace("cfm 1 # version\n\n  # note\nascent 1\ndescent 2\nspace 3 4 5\nextra 6\ndefault 7\nglyph 65 8 # A\n");
    assert(f.ascent == 1 && f.defaultAdv == 7 && f.adv('A') == 8 && f.adv('B') == 7);
}
