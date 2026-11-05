/// Unit tests: lexer, parser and evaluator (via complete builds).
module tests.test_lang;

import kiln;
import tests.helpers;

private string err(string main)
{
    return configError(["main.kiln": main]);
}

unittest // comment stripping, logical lines, line numbers
{
    auto ll = lexFile("let a = 1 # c\n\nlet b = f(\n  1,\n  2)\n", "x");
    assert(ll.length == 2);
    assert(ll[0].line == 1 && ll[1].line == 3);
    assert(ll[1].toks.length == 9);
    // '#' inside a string is content
    ll = lexFile("let a = \"#{1}\"\n", "x");
    assert(ll.length == 1 && ll[0].toks.length == 4);
}

unittest // lexical errors take precedence over grammar errors
{
    assert(err("let = 1\nlet x = \"abc\n") == "E_PARSE main.kiln:2");
    assert(err("let b = f(\n  \"unterminated\n)\n") == "E_PARSE main.kiln:1");
    assert(err("let a = (1\n") == "E_PARSE main.kiln:1");
    assert(err("let a = 1)\n") == "E_PARSE main.kiln:1");
    assert(err("let a = 1 | 2\n") == "E_PARSE main.kiln:1");
    assert(err("let a = 1 & 2\n") == "E_PARSE main.kiln:1");
}

unittest // block structure errors
{
    assert(err("when true {\nlet x = 1\n") == "E_PARSE main.kiln:1");
    assert(err("}\n") == "E_PARSE main.kiln:1");
    assert(err("each x in [1] {\n} otherwise {\n}\n") == "E_PARSE main.kiln:2");
    assert(err("when true {\n} otherwise {\n} otherwise {\n}\n") == "E_PARSE main.kiln:3");
    assert(err("when true {\n} otherwise {\n} elsewhen true {\n}\n") == "E_PARSE main.kiln:3");
    assert(err("{\n") == "E_PARSE main.kiln:1");
    assert(err("when true {\nwhen true {\n}\n") == "E_PARSE main.kiln:1");
}

unittest // reserved words and string literal errors
{
    assert(err("let in = 1\n") == "E_PARSE main.kiln:1");
    assert(err("let x = 1 |> cost\n") == "E_UNKNOWN_FUNC cost");
    assert(err("let x = \"{}\"\n") == "E_PARSE main.kiln:1");
    assert(err("let x = \"a}b\"\n") == "E_PARSE main.kiln:1");
    assert(err("let x = \"\\q\"\n") == "E_PARSE main.kiln:1");
    assert(err("let x = 1\nlet y = \"{x}\"\nout \"a\"\n") == "E_PARSE main.kiln:3");
}

unittest // expression semantics and error ordering
{
    assert(err("let a = \"a\" + [1]\n") == "E_TYPE operator +: expected int, got str");
    assert(err("let a = 5[\"a\"]\n") == "E_TYPE index: expected int, got str");
    assert(err("let a = 1 / 0\n") == "E_DIV_ZERO");
    assert(err("let a = true || (1 / 0)\n") == "");
    assert(err("let a = nope(undefined)\n") == "E_UNKNOWN_FUNC nope");
    assert(err("let a = upper(undefined, 2)\n") == "E_UNKNOWN_VAR undefined");
    assert(err("let a = upper(1)\n") == "E_TYPE fn upper argument 1: expected str, got int");
    assert(err("let a = pathjoin()\n") == "E_ARITY fn pathjoin: expected 1-8, got 0");
    assert(err("let a = [1][5]\n") == "E_ARG fn index: out of range");
    assert(err("let xs = [1]\nlet a = \"{xs}\"\n") == "E_INTERP list");
    assert(err("let a = 1\nlet a = 2\n") == "E_REDEFINE a");
    assert(err("set a = 1\n") == "E_SET_UNDEFINED a");
    assert(err("abort \"n={1 + 2}\"\n") == "E_ABORT n=3");
}

private string evalStr(string expr)
{
    auto v = workspace(["main.kiln": "step {\n out \"out/r\"\n cmd write(" ~ expr ~ ")\n}\ndefault \"out/r\"\n"]);
    auto log = runSession(v, "build\n");
    return cast(string) v.read("out/r");
}

unittest // built-in functions
{
    assert(evalStr(`join(split("a,,b", ","), "|")`) == "a||b");
    assert(evalStr(`substr("abcdef", -2, 5)`) == "ef");
    assert(evalStr(`substr("abcdef", 2, -1)`) == "");
    assert(evalStr(`stem("src/a.b.txt") ~ ext("src/a.b.txt")`) == "a.b.txt");
    assert(evalStr(`stem("src/.hidden") ~ "|" ~ ext("src/.hidden")`) == ".hidden|");
    assert(evalStr(`ext("src/x.")`) == ".");
    assert(evalStr(`pathjoin("out", "", "a.txt")`) == "out/a.txt");
    assert(evalStr(`join(map(["a", "b"], "out/%.o"), ",")`) == "out/a.o,out/b.o");
    assert(evalStr(`map(["a"], "100%%-%")[0]`) == "100%-a");
    assert(evalStr(`replace("aaa", "aa", "b")`) == "ba");
    assert(evalStr(`str(len([1, 2]) + sum(range(4)))`) == "8");
    assert(evalStr(`join(sort([3, 1, 2]), "")`) == "123");
    assert(evalStr(`join(uniq(["b", "a", "b"]), "")`) == "ba");
    assert(evalStr(`join(flatten([[1], 2, [3, 4]]), "")`) == "1234");
    assert(evalStr(`str(indexof(["x", "y"], "y"))`) == "1");
    assert(evalStr(`str(int("-0042") * 2)`) == "-84");
    assert(evalStr(`str(has([[1], [2]], [2]))`) == "true");
    assert(evalStr(`join(filter(["a.c", "b.h", "c/d.c"], "*.c"), ",")`) == "a.c");
    assert(evalStr(`join(reject(["a.c", "b.h"], "*.c"), ",")`) == "b.h");
    assert(evalStr(`trim("  x\n")`) == "x");
    assert(evalStr(`upper("aé")`) == "Aé");
    assert(evalStr(`"{{x}}" ~ "{1 + 2}"`) == "{x}3");
    assert(evalStr(`"a" ~ 'it''s'`) == "ait's");
    assert(evalStr(`str(-7 / 2) ~ str(-7 % 2)`) == "-3-1");
    assert(evalStr(`"x" |> upper |> replace("X", "y")`) == "y");
    assert(evalStr(`str([1, 2] < [1, 3]) ~ str("a" < 1)`) == "truefalse");
}

unittest // glob sees only eligible files and is sorted
{
    auto v = workspace(["main.kiln": "step {\n out \"out/l\"\n cmd write(join(glob(\"src/**\"), \",\"))\n}\ndefault \"out/l\"\n",
            "src/b.txt": "", "src/a/c.txt": "", "out/x": "", ".kiln-state": ""]);
    runSession(v, "build\n");
    assert(v.read("out/l") == "src/a/c.txt,src/b.txt");
}

unittest // scoping: set through scopes, rules capture scope by reference
{
    auto v = workspace(["main.kiln":
        "let acc = []\n" ~
        "rule add(x) {\n set acc = acc ++ [x]\n}\n" ~
        "each i in range(3) {\n use add(i)\n}\n" ~
        "when len(acc) == 3 {\n let local = 1\n set acc = acc ++ [99]\n}\n" ~
        "step {\n out \"out/r\"\n cmd write(join(acc, \",\"))\n}\ndefault \"out/r\"\n"]);
    runSession(v, "build\n");
    assert(v.read("out/r") == "0,1,2,99");
}

unittest // rule argument errors and recursion limit
{
    assert(err("rule r(a, b = 1) {\n}\nuse r()\n") == "E_ARG rule r: missing argument a");
    assert(err("rule r(a) {\n}\nuse r(1, 2)\n") == "E_ARITY rule r: expected 1, got 2");
    assert(err("rule r(a) {\n}\nuse r(1, a = 2)\n") == "E_ARG rule r: duplicate argument a");
    assert(err("rule r(a) {\n}\nuse r(b = 2)\n") == "E_ARG rule r: unknown argument b");
    assert(err("rule r() {\n use r()\n}\nuse r()\n") == "E_RULE_RECURSION r");
    assert(err("use nope()\n") == "E_UNKNOWN_RULE nope");
}

unittest // include
{
    assert(configError(["main.kiln": "include \"a.kiln\"\n", "a.kiln": "include \"main.kiln\"\n"])
            == "E_INCLUDE_CYCLE main.kiln");
    assert(configError(["main.kiln": "include \"zzz.kiln\"\n"]) == "E_INCLUDE_MISSING zzz.kiln");
    assert(configError(["main.kiln": "include \"a.kiln\"\ninclude \"a.kiln\"\n", "a.kiln": "let q = 1\n"])
            == "E_REDEFINE q");
    assert(configError(["main.kiln": "include \"bad path\"\n"]) == "E_BAD_PATH bad path");
}
