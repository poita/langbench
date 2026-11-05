/// Unit tests for the evaluator and the built-in functions (via full builds).
module eval_test;

import helpers;
import kiln.build;

/// Evaluates `expr` and returns the written text, or the error.
private string run(string expr, string prelude = "")
{
    import kiln.vfs;

    auto v = workspace(["main.kiln": prelude ~ "step {\n out \"out/r\"\n cmd write(\"{" ~ expr ~ "}\")\n}\ndefault \"out/r\"\n"]);
    auto rep = runBuild(v, [], 1);
    if (!rep.ok)
        return "ERR " ~ rep.error;
    return v.content("out/r");
}

unittest // arithmetic and precedence
{
    assert(run("1 + 2 * 3") == "7");
    assert(run("(1 + 2) * 3") == "9");
    assert(run("-7 / 2") == "-3");
    assert(run("-7 % 3") == "-1");
    assert(run("7 % -3") == "1");
    assert(run("5 / 0") == "ERR E_DIV_ZERO");
    assert(run("1 + \"a\"") == "ERR E_TYPE operator +: expected int, got str");
    assert(run("\"a\" + [1]") == "ERR E_TYPE operator +: expected int, got str");
}

unittest // comparison uses the total order
{
    assert(run("true < 0") == "true");
    assert(run("1 < \"a\"") == "true");
    assert(run("\"z\" < [0]") == "true");
    assert(run("[1, 2] < [1, 3]") == "true");
    assert(run("[1] < [1, 0]") == "true");
    assert(run("[1, [2]] == [1, [2]]") == "true");
    assert(run("1 == true") == "false");
}

unittest // short-circuit operators
{
    assert(run("true || undefined") == "true");
    assert(run("false && undefined") == "false");
    assert(run("false || undefined") == "ERR E_UNKNOWN_VAR undefined");
    assert(run("1 || true") == "ERR E_TYPE operator ||: expected bool, got int");
}

unittest // indexing
{
    assert(run("\"abc\"[1]") == "b");
    assert(run("\"abc\"[-1]") == "c");
    assert(run("[1, 2][5]") == "ERR E_ARG fn index: out of range");
    assert(run("5[\"a\"]") == "ERR E_TYPE index: expected int, got str");
    assert(run("5[0]") == "ERR E_TYPE index target: expected str|list, got int");
}

unittest // string functions
{
    assert(run("upper(\"aBcé\")") == "ABCé");
    assert(run("trim(\"  a b\\n\")") == "a b");
    assert(run("replace(\"aaa\", \"aa\", \"b\")") == "ba");
    assert(run("replace(\"a\", \"\", \"b\")") == "ERR E_ARG fn replace: empty pattern");
    assert(run("substr(\"abcdef\", -2, 5)") == "ef");
    assert(run("substr(\"abcdef\", 2, -1)") == "");
    assert(run("join(split(\"a,,b\", \",\"), \"|\")") == "a||b");
    assert(run("len(split(\"\", \",\"))") == "1");
    assert(run("int(\"-007\")") == "-7");
    assert(run("int(\"9223372036854775808\")") == "ERR E_ARG fn int: bad integer");
    assert(run("int(\"-9223372036854775808\")") == "-9223372036854775808");
    assert(run("int(\"+1\")") == "ERR E_ARG fn int: bad integer");
    assert(run("stem(\"src/a.b.txt\")") == "a.b");
    assert(run("ext(\"src/.hidden\")") == "");
    assert(run("stem(\"src/x.\")") == "x");
    assert(run("ext(\"src/x.\")") == ".");
    assert(run("pathjoin(\"out\", \"\", \"a.txt\")") == "out/a.txt");
    assert(run("pathjoin()") == "ERR E_ARITY fn pathjoin: expected 1-8, got 0");
    assert(run("map([\"a\"], \"100%%-%\")") == "ERR E_INTERP list");
    assert(run("join(map([\"a\"], \"100%%-%\"), \"\")") == "100%-a");
    assert(run("nope(undefined)") == "ERR E_UNKNOWN_FUNC nope");
    assert(run("upper(undefined, 2)") == "ERR E_UNKNOWN_VAR undefined");
    assert(run("upper(1, 2)") == "ERR E_ARITY fn upper: expected 1, got 2");
    assert(run("upper(1)") == "ERR E_TYPE fn upper argument 1: expected str, got int");
}

unittest // list functions
{
    assert(run("join(sort([3, 1, 2]), \",\")") == "1,2,3");
    assert(run("join(uniq([1, 2, 1, 3, 2]), \",\")") == "1,2,3");
    assert(run("join(reverse([1, 2, 3]), \",\")") == "3,2,1");
    assert(run("first([])") == "ERR E_ARG fn first: empty list");
    assert(run("sum([1, 2, 3])") == "6");
    assert(run("sum([1, \"a\"])") == "ERR E_TYPE fn sum element 1: expected int, got str");
    assert(run("len(flatten([[1, 2], 3, [[4]]]))") == "4");
    assert(run("len(zip([1, 2, 3], [\"a\"]))") == "1");
    assert(run("indexof([1, 2, 3], 3)") == "2");
    assert(run("has([[1]], [1])") == "true");
    assert(run("join(range(3), \"\")") == "012");
    assert(run("range(-1)") == "ERR E_ARG fn range: negative");
    assert(run("join(filter([\"a.txt\", \"b.md\"], \"*.txt\"), \"\")") == "a.txt");
    assert(run("join(reject([\"a.txt\", \"b.md\"], \"*.txt\"), \"\")") == "b.md");
    assert(run("filter([1], \"\")") == "ERR E_ARG fn filter: bad pattern");
    assert(run("filter([1], \"*\")") == "ERR E_TYPE fn filter element 0: expected str, got int");
    assert(run("join([[1]], \"\")") == "ERR E_TYPE fn join element 0: expected str|int, got list");
}

unittest // pipes
{
    assert(run("\"a,b\" |> split(\",\") |> join(\"-\")") == "a-b");
    assert(run("1 |> cost") == "ERR E_UNKNOWN_FUNC cost");
}

unittest // string literals
{
    assert(run("'it''s {x}'") == "it's {x}");
    assert(run("\"{{literal}}\"") == "{literal}");
    assert(run("\"a\\tb\"") == "a\tb");
    assert(run("\"{[1]}\"") == "ERR E_INTERP list");
}

unittest // scoping
{
    assert(run("x", "let x = 1\nwhen true {\n  let x = 2\n}\n") == "1");
    assert(run("x", "let x = 1\nwhen true {\n  set x = 2\n}\n") == "2");
    assert(run("x", "let x = 1\nlet x = 2\n") == "ERR E_REDEFINE x");
    assert(run("1", "set y = 2\n") == "ERR E_SET_UNDEFINED y");
    assert(run("x", "let x = 0\neach v in [1, 2, 3] {\n  set x = x + v\n}\n") == "6");
    assert(run("x", "let x = 0\neach i, v in [5, 6] {\n  set x = x + i * 10 + v\n}\n") == "21");
}

unittest // rules capture their defining scope by reference
{
    auto prelude = "let k = \"a\"\nrule r() {\n  set k = k ~ \"!\"\n}\nuse r()\nuse r()\n";
    assert(run("k", prelude) == "a!!");
}

unittest // rule argument binding
{
    auto base = "let out_ = []\nrule r(a, b = a + 1) {\n  set out_ = [a, b]\n}\n";
    assert(run("join(out_, \",\")", base ~ "use r(1)\n") == "1,2");
    assert(run("join(out_, \",\")", base ~ "use r(1, b = 5)\n") == "1,5");
    assert(run("1", base ~ "use r()\n") == "ERR E_ARG rule r: missing argument a");
    assert(run("1", base ~ "use r(1, 2, 3)\n") == "ERR E_ARITY rule r: expected 2, got 3");
    assert(run("1", base ~ "use r(1, a = 2)\n") == "ERR E_ARG rule r: duplicate argument a");
    assert(run("1", base ~ "use r(1, z = 2)\n") == "ERR E_ARG rule r: unknown argument z");
    assert(run("1", "use nope(undefined)\n") == "ERR E_UNKNOWN_RULE nope");
    assert(run("1", "rule r() {\n}\nrule r() {\n}\n") == "ERR E_REDEFINE r");
}

unittest // recursion depth limit
{
    auto rec = "rule r(n) {\n  when n > 0 {\n    use r(n - 1)\n  }\n}\n";
    assert(run("1", rec ~ "use r(63)\n") == "1");
    assert(run("1", rec ~ "use r(64)\n") == "ERR E_RULE_RECURSION r");
}

unittest // include semantics
{
    auto v = workspace(["main.kiln": "include \"a.kiln\"\nstep {\n out \"out/r\"\n cmd write(\"{x}\")\n}\ndefault \"out/r\"\n",
            "a.kiln": "let x = 7\n"]);
    auto rep = runBuild(v, [], 1);
    assert(rep.ok);
    assert(v.content("out/r") == "7");

    v = workspace(["main.kiln": "include \"main.kiln\"\n"]);
    assert(runBuild(v, [], 1).error == "E_INCLUDE_CYCLE main.kiln");
    v = workspace(["main.kiln": "include \"nope.kiln\"\n"]);
    assert(runBuild(v, [], 1).error == "E_INCLUDE_MISSING nope.kiln");
    v = workspace(["main.kiln": "include \"a.kiln\"\ninclude \"a.kiln\"\n", "a.kiln": "let q = 1\n"]);
    assert(runBuild(v, [], 1).error == "E_REDEFINE q");
}

unittest // glob sees the workspace but not out/ or the state file
{
    auto v = workspace(["main.kiln": "let g = glob(\"**\")\nabort join(g, \",\")\n",
            "src/b.txt": "", "src/a.txt": "", "out/x": "", ".kiln-state": ""]);
    assert(runBuild(v, [], 1).error == "E_ABORT main.kiln,src/a.txt,src/b.txt");
}
