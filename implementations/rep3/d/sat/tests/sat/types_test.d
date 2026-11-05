module sat.types_test;

import sat.types;

unittest // encoding of literals
{
    assert(fromDimacs(1) == 0 && fromDimacs(-1) == 1);
    assert(fromDimacs(3) == 4 && fromDimacs(-3) == 5);
    assert(mkLit(3, true) == 6 && mkLit(3, false) == 7);
}

unittest // round trips and negation
{
    foreach (d; [-50, -2, -1, 1, 2, 77])
    {
        assert(toDimacs(fromDimacs(d)) == d);
        assert(toDimacs(neg(fromDimacs(d))) == -d);
        assert(var(fromDimacs(d)) == (d > 0 ? d : -d) - 1);
    }
}
