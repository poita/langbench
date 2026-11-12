// Library behaviour: each section of SPEC.md section 15.
#include <gtest/gtest.h>

#include "builtins.h"
#include "support.h"

using testsupport::runMain;

namespace {
// Evaluates a Str-typed expression and returns what it prints.
std::string eval(const std::string& expr) { return runMain("fn main() { print(" + expr + "); }\n"); }
}  // namespace

TEST(Stdlib, ExactlyTheSpecifiedBuiltinsExist) {
  EXPECT_EQ(langvm::builtinCount(), 132);
  EXPECT_GE(langvm::builtinIndex("sortBy"), 0);
  EXPECT_EQ(langvm::builtinIndex("noSuchBuiltin"), -1);
}

TEST(Stdlib, FloatPrinting) {
  EXPECT_EQ(eval("showFloat(1.0)"), "1.000000\n");
  EXPECT_EQ(eval("showFloat(-0.0)"), "-0.000000\n");
  EXPECT_EQ(eval("showFloatAt(2.5, 0) ++ showFloatAt(3.5, 0) ++ showFloatAt(0.5, 0)"), "240\n");
  EXPECT_EQ(eval("showFloatAt(0.1 + 0.2, 17)"), "0.30000000000000004\n");
  EXPECT_EQ(eval("showFloatAt(1e21, 2)"), "1000000000000000000000.00\n");
  EXPECT_EQ(eval("showFloatAt(2.675, 2)"), "2.67\n");
  EXPECT_EQ(eval("showFloatAt(nanF(), 3) ++ \" \" ++ showFloatAt(-1.0 / 0.0, 3)"), "nan -inf\n");
  EXPECT_EQ(eval("showFloatAt(1.0, 18)"), "panic: digits out of range\n");
}

TEST(Stdlib, FloatFunctions) {
  EXPECT_EQ(eval("showFloat(roundF(-2.5)) ++ \" \" ++ showFloat(floorF(-2.5)) ++ \" \" ++ showFloat(ceilF(-0.5))"),
            "-3.000000 -3.000000 -0.000000\n");
  EXPECT_EQ(eval("showInt(truncToInt(-3.9))"), "-3\n");
  EXPECT_EQ(eval("showInt(truncToInt(1e30))"), "panic: float out of integer range\n");
  EXPECT_EQ(eval("showFloat(powF(2.0, 10)) ++ \" \" ++ showFloat(powF(2.0, -2))"), "1024.000000 0.250000\n");
  EXPECT_EQ(eval("showInt(cmpF(nanF(), 1.0)) ++ showInt(cmpF(1.0, nanF())) ++ showInt(cmpF(nanF(), nanF()))"), "1-10\n");
  EXPECT_EQ(eval("showFloat(minF(nanF(), 1.0)) ++ showFloat(minF(-0.0, 0.0))"), "1.000000-0.000000\n");
  EXPECT_EQ(eval("showInt(floatBits(1.0))"), "4607182418800017408\n");
  EXPECT_EQ(eval("showFloat(toFloat(9007199254740993))"), "9007199254740992.000000\n");
  EXPECT_EQ(eval("showFloat(unwrap(parseFloat(\"12.\"))) ++ showBool(isNone(parseFloat(\"1e\")))"), "12.000000true\n");
}

TEST(Stdlib, IntegerFunctions) {
  EXPECT_EQ(eval("showInt(divFloor(-7, 2)) ++ \" \" ++ showInt(modFloor(-7, 2))"), "-4 1\n");
  EXPECT_EQ(eval("showInt(divFloor(1, 0))"), "panic: divide by zero\n");
  EXPECT_EQ(eval("showInt(powI(3, 20)) ++ \" \" ++ showInt(gcdI(-84, 36)) ++ \" \" ++ showInt(gcdI(0, 0))"),
            "3486784401 12 0\n");
  EXPECT_EQ(eval("showInt(popCount(255)) ++ showInt(clz(1)) ++ showInt(ctz(0))"), "86364\n");
  EXPECT_EQ(eval("showIntRadix(255, 16) ++ \" \" ++ showIntRadix(-255, 2) ++ \" \" ++ showIntRadix(intMin(), 16)"),
            "ff -11111111 -8000000000000000\n");
  EXPECT_EQ(eval("showInt(unwrapOr(parseInt(\"-0042\"), 0)) ++ showBool(isNone(parseInt(\"9223372036854775808\")))"),
            "-42true\n");
  EXPECT_EQ(eval("showInt(unwrap(parseIntRadix(\"-ZZ\", 36)))"), "-1295\n");
  EXPECT_EQ(eval("showInt(absI(intMin()))"), "-9223372036854775808\n");
}

TEST(Stdlib, StringFunctions) {
  EXPECT_EQ(eval("showInt(strLen(\"h\\u{e9}llo\")) ++ showChar(charAt(\"h\\u{e9}llo\", 1))"), "5\xC3\xA9\n");
  EXPECT_EQ(eval("strJoin(strSplit(\"a,,b,\", \",\"), \"|\")"), "a||b|\n");
  EXPECT_EQ(eval("strJoin(strSplit(\"aaa\", \"aa\"), \"|\")"), "|a\n");
  EXPECT_EQ(eval("strReplace(\"aaa\", \"aa\", \"b\")"), "ba\n");
  EXPECT_EQ(eval("strReplace(\"abc\", \"\", \"b\")"), "panic: empty separator\n");
  EXPECT_EQ(eval("quoteStr(\"a\\\"b\\n\\u{1}\")"), "\"a\\\"b\\n\\u{1}\"\n");
  EXPECT_EQ(eval("quoteChar('\\'') ++ quoteChar('\"')"), "'\\'''\"'\n");
  EXPECT_EQ(eval("padLeft(\"7\", 3, '0') ++ padRight(\"x\", 3, '-') ++ padLeft(\"abcd\", 2, '*')"), "007x--abcd\n");
  EXPECT_EQ(eval("showInt(strIndexOf(\"hello\", \"l\")) ++ showInt(strLastIndexOf(\"hello\", \"l\")) ++ showInt(strIndexOf(\"x\", \"\"))"),
            "230\n");
  EXPECT_EQ(eval("upper(\"h\\u{e9}llo\") ++ trim(\"  x  \") ++ \"|\""), "H\xC3\xA9LLOx|\n");
  EXPECT_EQ(eval("showInt(strCmp(\"abc\", \"abd\")) ++ showInt(strCmp(\"ab\", \"ab\")) ++ showInt(strCmp(\"b\", \"ab\"))"),
            "-101\n");
  EXPECT_EQ(eval("substr(\"hello\", 3, 9)"), "panic: index out of bounds\n");
  EXPECT_EQ(eval("strRepeat(\"x\", -1)"), "panic: negative count\n");
  EXPECT_EQ(eval("showChar(chr(55296))"), "panic: invalid char code\n");
}

TEST(Stdlib, ListFunctions) {
  EXPECT_EQ(runMain(R"(fn main() {
    var xs = [3, 1, 2];
    push(xs, 5);
    insert(xs, 0, 9);
    print(showInt(removeAt(xs, 1)) ++ showInt(pop(xs)) ++ showInt(listLen(xs)));
    print(strJoin(listMap(reverseList(xs), |x| showInt(x)), ","));
    print(showInt(listFold(xs, 0, |a, x| a + x)) ++ showBool(listAny(xs, |x| x > 8)) ++ showBool(listAll(xs, |x| x > 8)));
    print(showInt(listFindIndex(xs, |x| x == 2)) ++ showInt(listIndexOf(xs, 7)));
    print(strJoin(listMap(listZip(xs, ["a", "b"]), |p| showInt(fst(p)) ++ snd(p)), ","));
    print(showInt(listLen(listFlatten([[1], [], [2, 3]]))));
})"),
            "353\n2,1,9\n12truefalse\n2-1\n9a,1b\n3\n");
}

TEST(Stdlib, ListPanics) {
  EXPECT_EQ(runMain("fn main() { let xs: [Int] = listNew(); print(showInt(pop(xs))); }\n"), "panic: empty list\n");
  EXPECT_EQ(runMain("fn main() { let xs = [1]; insert(xs, 3, 1); }\n"), "panic: index out of bounds\n");
  EXPECT_EQ(runMain("fn main() { let xs = [1]; print(showInt(listLen(slice(xs, 1, 0)))); }\n"),
            "panic: index out of bounds\n");
}

TEST(Stdlib, SortByIsAStableBottomUpMergeSort) {
  // Records the exact comparator calls the specification's algorithm makes.
  EXPECT_EQ(runMain(R"(fn main() {
    let xs = [3, 1, 2];
    let ys = sortBy(xs, |a, b| { emit(showInt(a) ++ showInt(b) ++ " "); cmpI(a, b) });
    print("");
    print(strJoin(listMap(ys, |x| showInt(x)), ","));
    print(strJoin(listMap(xs, |x| showInt(x)), ","));
    let pairs = [(1, "a"), (0, "b"), (1, "c"), (0, "d")];
    let sorted = sortBy(pairs, |p, q| cmpI(fst(p), fst(q)));
    print(strJoin(listMap(sorted, |p| snd(p)), ""));
})"),
            "31 12 32 \n1,2,3\n3,1,2\nbdac\n");
}

TEST(Stdlib, MapFunctions) {
  EXPECT_EQ(runMain(R"(fn main() {
    let m: #[Str: Int] = mapNew();
    mapSet(m, "a", 1);
    m["b"] = 2;
    print(showInt(mapLen(m)) ++ showBool(mapHas(m, "a")) ++ showInt(mapGetOr(m, "z", 9)) ++ showBool(mapDel(m, "a")) ++ showBool(mapDel(m, "a")));
    let c = mapCopy(m);
    mapClear(m);
    print(showInt(mapLen(m)) ++ showInt(mapLen(c)) ++ strJoin(keysOf(c), ""));
    print(showInt(unwrap(mapGet(c, "b"))));
})"),
            "2true9truefalse\n01b\n2\n");
}

TEST(Stdlib, OptionResultAndTuples) {
  EXPECT_EQ(runMain(R"(fn main() {
    let r: Result<Int, Str> = Err("bad");
    print(unwrapErr(r) ++ showBool(isErr(r)) ++ showBool(isOk(r)));
    let o: Option<Int> = None;
    print(showInt(unwrapOr(o, 5)));
    print(showInt(unwrap(o)));
})"),
            "badtruefalse\n5\npanic: unwrap of None\n");
}

TEST(Stdlib, Format) {
  EXPECT_EQ(eval("fmt(\"{} + {} = {{{}}}\", [\"1\", \"2\", \"3\"])"), "1 + 2 = {3}\n");
  EXPECT_EQ(eval("fmt(\"100%\", [])"), "100%\n");
  EXPECT_EQ(eval("fmt(\"{}\", [])"), "panic: bad format\n");
  EXPECT_EQ(eval("fmt(\"x}\", [])"), "panic: bad format\n");
  EXPECT_EQ(eval("fmt(\"{x}\", [\"a\"])"), "panic: bad format\n");
  EXPECT_EQ(eval("fmt(\"\", [\"a\"])"), "panic: bad format\n");
}
