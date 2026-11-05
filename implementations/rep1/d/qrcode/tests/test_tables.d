module tests.test_tables;

import qrcode.tables;

unittest // spec examples for data codeword counts
{
    assert(dataCodewords(1, Ecl.L) == 19);
    assert(dataCodewords(1, Ecl.M) == 16);
    assert(dataCodewords(1, Ecl.Q) == 13);
    assert(dataCodewords(1, Ecl.H) == 9);
    assert(dataCodewords(40, Ecl.L) == 2956);
    assert(dataCodewords(40, Ecl.H) == 1276);
}

unittest // raw module counts match the well-known values
{
    assert(rawDataModules(1) == 208);
    assert(rawDataModules(2) == 359);
    assert(rawDataModules(7) == 1568);
    assert(rawDataModules(40) == 29648);
}

unittest // block structure is consistent for every version and level
{
    foreach (ver; minVersion .. maxVersion + 1)
        foreach (ecl; [Ecl.L, Ecl.M, Ecl.Q, Ecl.H])
            assert(dataCodewords(ver, ecl) > 0);
}

unittest
{
    assert(symbolSize(1) == 21);
    assert(symbolSize(40) == 177);
    assert(alignmentPositions(1).length == 0);
    assert(alignmentPositions(7) == [6, 22, 38]);
    assert(alignmentPositions(40) == [6, 30, 58, 86, 114, 142, 170]);
    assert(formatBits(Ecl.L) == 1 && formatBits(Ecl.M) == 0
        && formatBits(Ecl.Q) == 3 && formatBits(Ecl.H) == 2);
}
