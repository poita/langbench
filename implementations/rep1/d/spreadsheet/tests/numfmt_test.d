module tests.numfmt_test;

import spreadsheet.cellref;
import spreadsheet.numfmt;

unittest // display rules
{
    assert(formatNumber(0) == "0");
    assert(formatNumber(-0.0) == "0");
    assert(formatNumber(42) == "42");
    assert(formatNumber(-7) == "-7");
    assert(formatNumber(123456789012345) == "123456789012345");
    assert(formatNumber(1e14) == "100000000000000");
    assert(formatNumber(1e15) == "1e+15");
    assert(formatNumber(1e20) == "1e+20");
    assert(formatNumber(-1.5e15) == "-1.5e+15");
    assert(formatNumber(1.23456789e15) == "1.23456789e+15");
    assert(formatNumber(0.00001) == "1e-05");
    assert(formatNumber(2.5e-10) == "2.5e-10");
    assert(formatNumber(0.5) == "0.5");
    assert(formatNumber(-2.5) == "-2.5");
    assert(formatNumber(1234567.891) == "1234567.891");
    assert(formatNumber(1.0 / 3) == "0.3333333333");
    assert(formatNumber(2.0 / 3) == "0.6666666667");
    assert(formatNumber(0.0001234) == "0.0001234");
    assert(formatNumber(1234567890.4) == "1234567890");
    assert(formatNumber(9999999999.7) == "1e+10");
}

unittest // exact ties round to even; near-ties follow the exact binary value
{
    assert(formatNumber(1234567890.5) == "1234567890");
    assert(formatNumber(1234567891.5) == "1234567892");
    assert(formatNumber(2500000000.75) == "2500000001");
    assert(formatNumber(1200000000.4) == "1200000000");
    assert(formatNumber(0.1) == "0.1");
}

unittest // literal parsing
{
    double d;
    assert(parseNumber("5", d) && d == 5);
    assert(parseNumber("-3", d) && d == -3);
    assert(parseNumber("4.50", d) && d == 4.5);
    assert(parseNumber("007", d) && d == 7);
    assert(parseNumber("0.1", d) && d == 0.1);
    assert(parseNumber("-0", d) && d == 0);
    assert(!parseNumber("", d));
    assert(!parseNumber("-", d));
    assert(!parseNumber("1.", d));
    assert(!parseNumber(".5", d));
    assert(!parseNumber("1e5", d));
    assert(!parseNumber("abc", d));
    assert(!parseNumber("1 2", d));
}

unittest // cell names
{
    CellRef r;
    assert(tryParseCellRef("A1", r) && r == CellRef(1, 1));
    assert(tryParseCellRef("Z9", r) && r == CellRef(26, 9));
    assert(tryParseCellRef("AA10", r) && r == CellRef(27, 10));
    assert(tryParseCellRef("ZZ9999", r) && r == CellRef(702, 9999));
    foreach (bad; ["", "A", "1", "a1", "AAA1", "A0", "A01", "A10000", "A1B", "A-1"])
        assert(!tryParseCellRef(bad, r), bad);
    assert(CellRef(27, 10).toString() == "AA10");
    assert(CellRef(26, 1).toString() == "Z1");
    assert(CellRef(702, 9999).toString() == "ZZ9999");
    assert(CellRef.fromKey(CellRef(5, 7).key) == CellRef(5, 7));
    // keys sort row-major
    assert(CellRef(702, 1).key < CellRef(1, 2).key);
}
