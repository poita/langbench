module tests.arith_test;

import typeset.arith;

unittest // floor division rounds towards negative infinity
{
    assert(fdiv(7, 2) == 3);
    assert(fdiv(-7, 2) == -4);
    assert(fdiv(-3890 * 850, 5100) == -649);
    assert(fdiv(0, 5) == 0);
}

unittest // scaling happens once, in glyph space
{
    assert(scale(1563, 10000) == 15630);
    assert(scale(1054, 11000) == 11594);
    assert(scale(-60, 10000) == -600);
    assert(scale(1, 1) == 0);
}

unittest // numerals
{
    assert(toRoman(1) == "i");
    assert(toRoman(14) == "xiv");
    assert(toRoman(2026) == "mmxxvi");
    assert(toRoman(4000) == "mmmm");
    assert(toLetters(1) == "a");
    assert(toLetters(26) == "z");
    assert(toLetters(27) == "aa");
    assert(toLetters(52) == "az");
    assert(toLetters(53) == "ba");
    assert(toDecimal(0) == "0");
    assert(toDecimal(-1205) == "-1205");
}

unittest // badness table of the specification (Example 3)
{
    auto a = evaluateLine(142000, 1270, 850, false, 142000);
    assert(a.badness == 0 && a.fitness == Fitness.decent);
    auto b = evaluateLine(130980, 6350, 4250, false, 142000);
    assert(b.badness == 522 && b.fitness == Fitness.veryLoose);
    auto c = evaluateLine(145890, 7620, 5100, false, 142000);
    assert(c.badness == 44 && c.fitness == Fitness.tight);
    auto d = evaluateLine(111050, 5080, 3400, false, 142000);
    assert(d.badness == 10000 && d.fitness == Fitness.veryLoose);
    assert(evaluateLine(164800, 8890, 5950, false, 142000).kind == LineKind.overfull);
    assert(evaluateLine(15630, 0, 0, false, 142000).kind == LineKind.unstretchable);
}

unittest // the infinite glue excuses a short line but not an overfull one
{
    assert(evaluateLine(1000, 0, 0, true, 142000).badness == 0);
    assert(evaluateLine(200000, 0, 0, true, 142000).kind == LineKind.overfull);
}

unittest // badness stays exact when 100 * d^3 does not fit in 64 bits
{
    // d = 1_000_000, y = 400_000: 100 * d^3 = 1e20 > 2^64; 1e20 div 6.4e16 = 1562.
    assert(cubicBadness(1_000_000, 400_000) == 1562);
    assert(cubicBadness(2_000_000, 400_000) == 10000);
    // d = 1_000_000, y = 2_100_000: (100 * 1e18) div (9.261e18) = 10
    assert(cubicBadness(1_000_000, 2_100_000) == 10);
    assert(cubicBadness(1, 1) == 100);
    assert(cubicBadness(0, 7) == 0);
}
