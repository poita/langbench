module test_expressions;

import helpers;

unittest
{
    // arithmetic and precedence
    assert(evalExpr("1 + 2 * 3") == "7");
    assert(evalExpr("(1 + 2) * 3") == "9");
    assert(evalExpr("-7 / 2") == "-3");
    assert(evalExpr("-7 % 3") == "-1");
    assert(evalExpr("7 % -3") == "1");
    assert(evalExpr("1 / 0") == "!E_DIV_ZERO");
    assert(evalExpr("1 % 0") == "!E_DIV_ZERO");
    assert(evalExpr("--3") == "3");
    assert(evalExpr("\"a\" ~ \"b\" ~ \"c\"") == "abc");
    assert(evalExpr("join([1] ++ [2] ++ [\"x\"], \"-\")") == "1-2-x");
}

unittest
{
    // type errors and their order
    assert(evalExpr("\"a\" + [1]") == "!E_TYPE operator +: expected int, got str");
    assert(evalExpr("1 + \"a\"") == "!E_TYPE operator +: expected int, got str");
    assert(evalExpr("!1") == "!E_TYPE operator !: expected bool, got int");
    assert(evalExpr("-\"a\"") == "!E_TYPE operator -: expected int, got str");
    assert(evalExpr("5[\"a\"]") == "!E_TYPE index: expected int, got str");
    assert(evalExpr("5[0]") == "!E_TYPE index target: expected str|list, got int");
    assert(evalExpr("[1][3]") == "!E_ARG fn index: out of range");
    assert(evalExpr("[1,2,3][-1]") == "3");
    assert(evalExpr("\"abc\"[1]") == "b");
    assert(evalExpr("1 ~ 2") == "!E_TYPE operator ~: expected str, got int");
    assert(evalExpr("1 ++ [2]") == "!E_TYPE operator ++: expected list, got int");
}

unittest
{
    // short-circuit
    assert(evalExpr("true || undefined") == "true");
    assert(evalExpr("false && undefined") == "false");
    assert(evalExpr("false || undefined") == "!E_UNKNOWN_VAR undefined");
    assert(evalExpr("1 || true") == "!E_TYPE operator ||: expected bool, got int");
    assert(evalExpr("true && 1") == "!E_TYPE operator &&: expected bool, got int");
}

unittest
{
    // total order and equality
    assert(evalExpr("true < 0") == "true");
    assert(evalExpr("5 < \"a\"") == "true");
    assert(evalExpr("\"z\" < [1]") == "true");
    assert(evalExpr("\"ab\" < \"b\"") == "true");
    assert(evalExpr("[1,2] < [1,2,0]") == "true");
    assert(evalExpr("[1,[2]] == [1,[2]]") == "true");
    assert(evalExpr("1 == \"1\"") == "false");
    assert(evalExpr("1 != \"1\"") == "true");
}

unittest
{
    // string literals and interpolation
    assert(evalExpr("\"out/x{1 + 6}.txt\"") == "out/x7.txt");
    assert(evalExpr("\"{{literal}}\"") == "{literal}");
    assert(evalExpr("\"{[1][0]}-{true}\"") == "1-true");
    assert(evalExpr("\"{[1]}\"") == "!E_INTERP list");
    assert(evalExpr("'a\\nb{x}'") == "a\\nb{x}");
    assert(evalExpr("'it''s'") == "it's");
    assert(evalExpr("\"tab\\tq\\\"\"") == "tab\tq\"");
}

unittest
{
    // function call protocol
    assert(evalExpr("nope(undefined)") == "!E_UNKNOWN_FUNC nope");
    assert(evalExpr("upper(undefined, 2)") == "!E_UNKNOWN_VAR undefined");
    assert(evalExpr("upper(\"a\", 2)") == "!E_ARITY fn upper: expected 1, got 2");
    assert(evalExpr("pathjoin()") == "!E_ARITY fn pathjoin: expected 1-8, got 0");
    assert(evalExpr("upper(1)") == "!E_TYPE fn upper argument 1: expected str, got int");
    assert(evalExpr("len(1)") == "!E_TYPE fn len argument 1: expected str|list, got int");
    assert(evalExpr("1 |> cost") == "!E_UNKNOWN_FUNC cost");
    assert(evalExpr("\"ab\" |> upper |> replace(\"A\", \"x\")") == "xB");
}

unittest
{
    // string functions
    assert(evalExpr("upper(\"aZé\")") == "AZé");
    assert(evalExpr("trim(\" \\t\\nx y\\r\\n\")") == "x y");
    assert(evalExpr("replace(\"aaa\", \"aa\", \"b\")") == "ba");
    assert(evalExpr("replace(\"a\", \"\", \"b\")") == "!E_ARG fn replace: empty pattern");
    assert(evalExpr("substr(\"abcdef\", 1, 3)") == "bcd");
    assert(evalExpr("substr(\"abcdef\", -2, 5)") == "ef");
    assert(evalExpr("substr(\"abcdef\", 10, 2)") == "");
    assert(evalExpr("substr(\"abcdef\", 2, -1)") == "");
    assert(evalExpr("join(split(\"a,,b\", \",\"), \"|\")") == "a||b");
    assert(evalExpr("len(split(\"\", \",\"))") == "1");
    assert(evalExpr("split(\"a\", \"\")") == "!E_ARG fn split: empty separator");
    assert(evalExpr("int(\"-007\")") == "-7");
    assert(evalExpr("int(\"+7\")") == "!E_ARG fn int: bad integer");
    assert(evalExpr("int(\"9223372036854775808\")") == "!E_ARG fn int: bad integer");
    assert(evalExpr("int(\"-9223372036854775808\")") == "-9223372036854775808");
    assert(evalExpr("dirname(\"a/b/c\")") == "a/b");
    assert(evalExpr("dirname(\"c\")") == "");
    assert(evalExpr("basename(\"a/b/c\")") == "c");
    assert(evalExpr("stem(\"src/a.b.txt\")") == "a.b");
    assert(evalExpr("ext(\"src/a.b.txt\")") == ".txt");
    assert(evalExpr("ext(\"src/.hidden\")") == "");
    assert(evalExpr("ext(\"src/x.\")") == ".");
    assert(evalExpr("pathjoin(\"out\", \"\", \"a.txt\")") == "out/a.txt");
    assert(evalExpr("pathjoin(\"out/\")") == "out/");
    assert(evalExpr("join(map([\"a\"], \"100%%-%\"), \"\")") == "100%-a");
    assert(evalExpr("join([1, [2]], \",\")") == "!E_TYPE fn join element 1: expected str|int, got list");
}

unittest
{
    // list functions
    assert(evalExpr("join(sort([3, 1, 2]), \",\")") == "1,2,3");
    assert(evalExpr("join(uniq([\"a\", \"b\", \"a\"]), \",\")") == "a,b");
    assert(evalExpr("join(reverse([1, 2, 3]), \",\")") == "3,2,1");
    assert(evalExpr("first([])") == "!E_ARG fn first: empty list");
    assert(evalExpr("last([])") == "!E_ARG fn last: empty list");
    assert(evalExpr("last([1, 2])") == "2");
    assert(evalExpr("join(slice([1, 2, 3, 4], -2, 9), \",\")") == "3,4");
    assert(evalExpr("has([[1], 2], [1])") == "true");
    assert(evalExpr("indexof([1, 2], 3)") == "-1");
    assert(evalExpr("join(range(3), \",\")") == "0,1,2");
    assert(evalExpr("range(-1)") == "!E_ARG fn range: negative");
    assert(evalExpr("sum([1, 2, 3])") == "6");
    assert(evalExpr("sum([1, \"a\"])") == "!E_TYPE fn sum element 1: expected int, got str");
    assert(evalExpr("len(flatten([[1, 2], 3, [[4]]]))") == "4");
    assert(evalExpr("len(zip([1, 2, 3], [\"a\"]))") == "1");
    assert(evalExpr("filter([1], \"\")") == "!E_ARG fn filter: bad pattern");
    assert(evalExpr("join(filter([\"a.txt\", \"b.md\"], \"*.txt\"), \",\")") == "a.txt");
    assert(evalExpr("join(reject([\"a.txt\", \"b.md\"], \"*.txt\"), \",\")") == "b.md");
    assert(evalExpr("filter([1], \"*\")") == "!E_TYPE fn filter element 0: expected str, got int");
    assert(evalExpr("str(true) ~ str(-3)") == "true-3");
    assert(evalExpr("str([1])") == "!E_TYPE fn str argument 1: expected str|int|bool, got list");
}

unittest
{
    // glob sees the workspace but never out/ or .kiln-state
    string[string] files = [
        "src/b.txt": "", "src/a.txt": "", "src/sub/c.txt": "", "src/n.md": "",
        "out/g.txt": "", ".kiln-state": "",
    ];
    assert(evalExpr("join(glob(\"src/**/*.txt\"), \",\")", files) == "src/a.txt,src/b.txt,src/sub/c.txt");
    assert(evalExpr("join(glob(\"**\"), \",\")", files) == "main.kiln,src/a.txt,src/b.txt,src/n.md,src/sub/c.txt");
    assert(evalExpr("glob(\"\")", files) == "!E_ARG fn glob: bad pattern");
}
