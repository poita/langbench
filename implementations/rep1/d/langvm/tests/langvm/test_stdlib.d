/// Tests for the standard library built-ins.
module langvm.test_stdlib;

import langvm;
import langvm.helpers;
import langvm.signatures;
import langvm.stdlib;

unittest
{
    // every signature has an implementation
    auto impls = builtinImplementations();
    assert(builtinSignatures.length == 132);
    assert(impls.length == 132);
    foreach (s; builtinSignatures)
    {
        size_t e = 0;
        while (s[e] != '(' && s[e] != '<')
            e++;
        assert(s[0 .. e] in impls, s);
    }
}

unittest
{
    expectBody("print(showFloat(1.0 / 3.0));\nprint(showFloatAt(2.5, 0) ++ \" \" ++ showFloatAt(3.5, 0));\n"
            ~ "print(showFloat(-0.0));\nprint(showFloat(roundF(-2.5)) ++ \" \" ++ showFloat(floorF(-2.5)));\n"
            ~ "print(showFloat(powF(2.0, -2)));\nprint(showFloatAt(nanF(), 2) ++ showFloatAt(-1.0 / 0.0, 2));",
        "0.333333\n2 4\n-0.000000\n-3.000000 -3.000000\n0.250000\nnan-inf\n");
    expectBody("print(showFloat(toFloat(9007199254740993)));\nprint(showInt(floatBits(1.0)));\n"
            ~ "print(showBool(nanF() == nanF()) ++ showInt(cmpF(nanF(), 1.0)));", "9007199254740992.000000\n4607182418800017408\nfalse1\n");
}

unittest
{
    expectBody("let s = \"héllo, wörld\";\nprint(showInt(strLen(s)));\nprint(substr(s, 7, 12));\nprint(upper(s));\n"
            ~ "print(strJoin(strSplit(\"a,,b,\", \",\"), \"|\"));\nprint(strReplace(\"aaa\", \"aa\", \"b\"));\n"
            ~ "print(quoteStr(\"tab\\there\\n\"));\nprint(padLeft(\"7\", 3, '0') ++ padRight(\"x\", 3, '-'));",
        "12\nwörld\nHéLLO, WöRLD\na||b|\nba\n\"tab\\there\\n\"\n007x--\n");
    expectBody("print(trim(\"  pad  \") ++ \"!\" ++ strReverse(\"abc\") ++ showInt(strCmp(\"b\", \"ab\")));", "pad!cba1\n");
}

unittest
{
    expectBody("let xs = [5, 3, 8, 1];\nprint(strJoin(listMap(sortBy(xs, |a, b| cmpI(a, b)), |v| showInt(v)), \",\"));\n"
            ~ "print(showInt(listFold(xs, 0, |a, x| a + x)));\nprint(showInt(listLen(listFilter(xs, |x| x > 2))));\n"
            ~ "print(showInt(unwrap(listFind(xs, |x| x > 4))) ++ showInt(listFindIndex(xs, |x| x == 1)));",
        "1,3,5,8\n17\n3\n53\n");
    // sortBy is stable and calls the comparator in the specified bottom-up order
    expectBody("let ps = [(2, \"b\"), (1, \"x\"), (2, \"a\"), (1, \"y\")];\n"
            ~ "let s = sortBy(ps, |p, q| cmpI(fst(p), fst(q)));\nprint(strJoin(listMap(s, |p| snd(p)), \"\"));", "xyba\n");
}

unittest
{
    expectBody("print(fmt(\"{} + {} = {}\", [\"1\", \"2\", \"3\"]) ++ fmt(\"{{{}}}\", [\"x\"]) ++ fmt(\"100%\", []));", "1 + 2 = 3{x}100%\n");
    expectBody("print(fmt(\"{}\", []));", "panic: bad format\n");
    expectBody("print(showIntRadix(255, 16) ++ \" \" ++ showIntRadix(-255, 2));\nprint(showInt(gcdI(-84, 36)) ++ \" \" ++ showInt(powI(3, 20)));",
        "ff -11111111\n12 3486784401\n");
    expectBody("print(showBool(parseInt(\"x\") == None));\nprint(showInt(unwrapOr(parseInt(\"-0042\"), 0)));", "true\n-42\n");
}
