module types_test;

import sat.types;

@safe pure nothrow @nogc unittest
{
    assert(mkLit(0) == 0 && mkLit(0, true) == 1 && mkLit(3, true) == 7);
    assert(neg(6) == 7 && neg(7) == 6);
    assert(varOf(7) == 3 && isNeg(7) && !isNeg(6));
}

@safe pure nothrow @nogc unittest
{
    assert(fromDimacs(1) == 0 && fromDimacs(-1) == 1 && fromDimacs(-4) == 7);
    assert(toDimacs(7) == -4 && toDimacs(0) == 1);
    foreach (d; [-50, -2, -1, 1, 2, 77])
        assert(toDimacs(fromDimacs(d)) == d);
}
