"""Expressions, built-in functions, statements and scoping."""

import pytest


class TestExpressions:
    @pytest.mark.parametrize(
        "expr,value",
        [
            ("1 + 2 * 3", 7),
            ("(1 + 2) * 3", 9),
            ("7 / 2", 3),
            ("-7 / 2", -3),
            ("7 / -2", -3),
            ("-7 % 3", -1),
            ("7 % -3", 1),
            ("- - 4", 4),
            ('"a" ~ "b" ~ "c"', b"abc"),
            ("[1] ++ [2] ++ [3]", [1, 2, 3]),
            ("1 < 2 && 2 < 3", True),
            ("true || nope", True),            # short circuit: right side never evaluated
            ("false && nope", False),
            ("!false", True),
            ('"a" < "b"', True),
            ('"ab" > "a"', True),
            ("true < 0", True),                # bool < int < str < list
            ('0 < "a"', True),
            ('"z" < []', True),
            ("[1, 2] < [1, 3]", True),
            ("[1] < [1, 0]", True),
            ("[1] == [true]", False),          # different types are never equal
            ("[[1], 2] == [[1], 2]", True),
            ('"abc"[1]', b"b"),
            ('"abc"[-1]', b"c"),
            ("[1, 2, 3][-3]", 1),
            ('"x" |> upper', b"X"),
            ('"a,b" |> split(",") |> join("-")', b"a-b"),
            ('"{1 + 1}-{true}-{"s"}-{-3}"', b"2-true-s--3"),
            ('"{{lit}}"', b"{lit}"),
            ("'a\\nb{x}'", b"a\\nb{x}"),
            ("'it''s'", b"it's"),
            ('"tab\\there\\0"', b"tab\there\x00"),
        ],
    )
    def test_values(self, kbl, expr, value):
        assert kbl(expr) == value
        assert type(kbl(expr)) is type(value)

    @pytest.mark.parametrize(
        "expr,error",
        [
            ('"a" + [1]', "E_TYPE operator +: expected int, got str"),
            ("1 + true", "E_TYPE operator +: expected int, got bool"),
            ("1 ~ 2", "E_TYPE operator ~: expected str, got int"),
            ("1 ++ [1]", "E_TYPE operator ++: expected list, got int"),
            ("!1", "E_TYPE operator !: expected bool, got int"),
            ('-"a"', "E_TYPE operator -: expected int, got str"),
            ("1 || true", "E_TYPE operator ||: expected bool, got int"),
            ("true && 1", "E_TYPE operator &&: expected bool, got int"),
            ("1 / 0", "E_DIV_ZERO"),
            ("1 % 0", "E_DIV_ZERO"),
            ('5["a"]', "E_TYPE index: expected int, got str"),
            ("5[0]", "E_TYPE index target: expected str|list, got int"),
            ("[1][1]", "E_ARG fn index: out of range"),
            ("[1][-2]", "E_ARG fn index: out of range"),
            ("nope(undefined)", "E_UNKNOWN_FUNC nope"),
            ("upper(undefined, 2)", "E_UNKNOWN_VAR undefined"),
            ("upper()", "E_ARITY fn upper: expected 1, got 0"),
            ("pathjoin()", "E_ARITY fn pathjoin: expected 1-8, got 0"),
            ("upper(1)", "E_TYPE fn upper argument 1: expected str, got int"),
            ('"{[1]}"', "E_INTERP list"),
            ("1 |> cost", "E_UNKNOWN_FUNC cost"),
        ],
    )
    def test_errors(self, kbl_error, expr, error):
        assert kbl_error(expr) == error

    def test_right_operand_evaluated_before_left_type_check(self, kbl_error):
        assert kbl_error('"a" + nope') == "E_UNKNOWN_VAR nope"


class TestBuiltins:
    @pytest.mark.parametrize(
        "expr,value",
        [
            ('len("héllo")', 6),                                  # bytes, not code points
            ("len([1, 2])", 2),
            ("count([1, 2, 3])", 3),
            ('upper("aé1")', "AÉ1".replace("É", "é").encode()),
            ('lower("ABC")', b"abc"),
            ('trim(" \\t\\r\\nx y\\n ")', b"x y"),
            ('replace("aaa", "aa", "b")', b"ba"),
            ('starts_with("abc", "")', True),
            ('ends_with("abc", "bc")', True),
            ('contains("abc", "")', True),
            ('substr("abcdef", 1, 3)', b"bcd"),
            ('substr("abcdef", -2, 5)', b"ef"),
            ('substr("abcdef", 10, 2)', b""),
            ('substr("abcdef", 2, -1)', b""),
            ('split("a,,b", ",")', [b"a", b"", b"b"]),
            ('split("", ",")', [b""]),
            ('join(["a", 1, "b"], "-")', b"a-1-b"),
            ("join([], \"x\")", b""),
            ('str(12)', b"12"),
            ('str(true)', b"true"),
            ('int("-007")', -7),
            ('int(5)', 5),
            ('dirname("a/b/c.txt")', b"a/b"),
            ('dirname("c.txt")', b""),
            ('basename("a/b/c.txt")', b"c.txt"),
            ('stem("src/a.b.txt")', b"a.b"),
            ('ext("src/a.b.txt")', b".txt"),
            ('stem("src/.hidden")', b".hidden"),
            ('ext("src/.hidden")', b""),
            ('ext("src/x.")', b"."),
            ('stem("src/a")', b"a"),
            ('pathjoin("out", "", "a.txt")', b"out/a.txt"),
            ('pathjoin("out/")', b"out/"),
            ('map(["a", "b"], "out/%.o")', [b"out/a.o", b"out/b.o"]),
            ('map(["a"], "100%%-%")', [b"100%-a"]),
            ('filter(["a.c", "b.h", "c.c"], "*.c")', [b"a.c", b"c.c"]),
            ('reject(["a.c", "b.h", "c.c"], "*.c")', [b"b.h"]),
            ('sort([3, "a", true, [1], 1])', [True, 1, 3, b"a", [1]]),
            ("uniq([1, true, 1, [1], [1], true])", [1, True, [1]]),
            ("reverse([1, 2, 3])", [3, 2, 1]),
            ("first([4, 5])", 4),
            ("last([4, 5])", 5),
            ("slice([1, 2, 3, 4], 1, 2)", [2, 3]),
            ("slice([1, 2, 3, 4], -1, 9)", [4]),
            ("has([[1], 2], [1])", True),
            ("has([1], true)", False),
            ("indexof([1, 2, 1], 1)", 0),
            ("indexof([1, 2], 3)", -1),
            ("range(3)", [0, 1, 2]),
            ("range(0)", []),
            ("sum([1, 2, 3])", 6),
            ("sum([])", 0),
            ("flatten([1, [2, [3]], []])", [1, 2, [3]]),
            ("zip([1, 2, 3], [4, 5])", [[1, 4], [2, 5]]),
            ("is_str(\"a\")", True),
            ("is_int(true)", False),
            ("is_bool(true)", True),
            ("is_list([])", True),
        ],
    )
    def test_values(self, kbl, expr, value):
        assert kbl(expr) == value

    @pytest.mark.parametrize(
        "expr,error",
        [
            ('replace("a", "", "b")', "E_ARG fn replace: empty pattern"),
            ('split("a", "")', "E_ARG fn split: empty separator"),
            ('int("+1")', "E_ARG fn int: bad integer"),
            ('int(" 1")', "E_ARG fn int: bad integer"),
            ('int("")', "E_ARG fn int: bad integer"),
            ('int("9223372036854775808")', "E_ARG fn int: bad integer"),
            ("first([])", "E_ARG fn first: empty list"),
            ("last([])", "E_ARG fn last: empty list"),
            ("range(-1)", "E_ARG fn range: negative"),
            ("join([[1]], \",\")", "E_TYPE fn join element 0: expected str|int, got list"),
            ('map([1], "%")', "E_TYPE fn map element 0: expected str, got int"),
            ("sum([1, \"a\"])", "E_TYPE fn sum element 1: expected int, got str"),
            ('filter([1], "")', "E_ARG fn filter: bad pattern"),
            ('reject(["a"], "[")', "E_ARG fn reject: bad pattern"),
            ('filter(["a", 1], "*")', "E_TYPE fn filter element 1: expected str, got int"),
            ('glob("")', "E_ARG fn glob: bad pattern"),
            ("len(1)", "E_TYPE fn len argument 1: expected str|list, got int"),
            ("count(\"a\")", "E_TYPE fn count argument 1: expected list, got str"),
            ("str([])", "E_TYPE fn str argument 1: expected str|int|bool, got list"),
            ("int(true)", "E_TYPE fn int argument 1: expected str|int, got bool"),
            ('substr("a", true, 1)', "E_TYPE fn substr argument 2: expected int, got bool"),
        ],
    )
    def test_errors(self, kbl_error, expr, error):
        assert kbl_error(expr) == error

    def test_glob_sees_workspace(self, kbl):
        files = {"src/b.txt": "", "src/a.txt": "", "src/n.md": "", "out/x.txt": "", "main.kiln": ""}
        assert kbl('glob("src/*.txt")', files) == [b"src/a.txt", b"src/b.txt"]
        assert kbl('glob("**")', files) == [b"main.kiln", b"src/a.txt", b"src/b.txt", b"src/n.md"]


class TestStatements:
    def test_scoping_and_shadowing(self, session):
        res = session(
            {
                "main.kiln": """
let x = 1
when true {
    let x = 2
    set x = 3
}
each i in [1, 2] {
    set x = x + 10
}
step {
    out "out/x.txt"
    cmd write("{x}")
}
default "out/x.txt"
"""
            },
            "build",
        )
        assert res.file("out/x.txt") == "21"

    def test_include_runs_in_current_scope(self, session):
        res = session(
            {
                "main.kiln": 'let a = 1\ninclude "inc.kiln"\ndefault "out/{a}{b}.txt"\n',
                "inc.kiln": 'set a = 2\nlet b = 3\nstep {\n out "out/23.txt"\n cmd write("")\n}\n',
            },
            "build",
        )
        assert "ok ran=1" in res.log

    def test_rules_see_defining_scope_by_reference(self, session):
        res = session(
            {
                "main.kiln": """
let tag = "a"
rule r(n) {
    step {
        out "out/{n}.txt"
        cmd write(tag)
    }
}
set tag = "later"
use r("x")
default "out/x.txt"
"""
            },
            "build",
        )
        assert res.file("out/x.txt") == "later"

    @pytest.mark.parametrize(
        "main,error",
        [
            ("let a = 1\nlet a = 2\n", "E_REDEFINE a"),
            ("let a = nope\nlet a = 2\n", "E_UNKNOWN_VAR nope"),
            ("set a = 1\n", "E_SET_UNDEFINED a"),
            ('include "nope.kiln"\n', "E_INCLUDE_MISSING nope.kiln"),
            ('include "main.kiln"\n', "E_INCLUDE_CYCLE main.kiln"),
            ('include "/x"\n', "E_BAD_PATH /x"),
            ("include 1\n", "E_TYPE include path: expected str, got int"),
            ('abort "bye {1}"\n', "E_ABORT bye 1"),
            ("abort 1\n", "E_TYPE abort message: expected str, got int"),
            ("when 1 {\n}\n", "E_TYPE when condition: expected bool, got int"),
            ("each x in 1 {\n}\n", "E_TYPE each subject: expected list, got int"),
            ("default 1\n", "E_TYPE default: expected strlist, got int"),
            ("default [1]\n", "E_TYPE default: expected strlist, got int"),
            ('phony a = 1\n', "E_TYPE phony a: expected strlist, got int"),
            ('phony a = ["bad path"]\n', "E_BAD_PATH bad path"),
            ('phony a = []\nphony a = []\n', "E_DUP_PHONY a"),
            ('phony a = nope\nphony a = nope\n', "E_UNKNOWN_VAR nope"),
            ("use nope()\n", "E_UNKNOWN_RULE nope"),
            ("rule r() {\n}\nrule r() {\n}\n", "E_REDEFINE r"),
            ("rule r(a) {\n}\nuse r(1, 2)\n", "E_ARITY rule r: expected 1, got 2"),
            ("rule r(a) {\n}\nuse r(b = 1)\n", "E_ARG rule r: unknown argument b"),
            ("rule r(a) {\n}\nuse r(1, a = 2)\n", "E_ARG rule r: duplicate argument a"),
            ("rule r(a, b) {\n}\nuse r(1)\n", "E_ARG rule r: missing argument b"),
            ("rule r() {\n    use r()\n}\nuse r()\n", "E_RULE_RECURSION r"),
            ('step {\n cmd write("x")\n}\n', "E_STEP_FIELD missing out"),
            ('step {\n out "out/x"\n}\n', "E_STEP_FIELD missing cmd"),
            ('step {\n out "out/x"\n cmd nope()\n}\n', "E_UNKNOWN_CMD nope"),
            ('step {\n out "out/x"\n cmd write("a")\n cmd write("b")\n}\n', "E_STEP_FIELD duplicate cmd"),
            ('step {\n cost 1\n cost nope\n}\n', "E_STEP_FIELD duplicate cost"),
            ('step {\n depfile "out/a"\n depfile "out/b"\n}\n', "E_STEP_FIELD duplicate depfile"),
            ('step {\n out "out/x"\n cost -1\n cmd write("")\n}\n', "E_ARG field cost: negative"),
            ('step {\n out 1\n}\n', "E_TYPE field out: expected strlist, got int"),
            ('step {\n out ["a", []]\n}\n', "E_TYPE field out: expected strlist, got list"),
            ('step {\n out "src/x"\n cmd write("")\n}\n', "E_OUTPUT_PATH src/x"),
            ('step {\n out "out/ x"\n cmd write("")\n}\n', "E_BAD_PATH out/ x"),
            ('step {\n out "out/x"\n in "@"\n cmd write("")\n}\n', "E_BAD_PATH @"),
            ('step {\n out "out/x"\n in "a"\n cmd write("")\n}\n', "E_CMD_SHAPE write: expected inputs 0-0, got 1"),
            ('step {\n out "out/x"\n cmd copy()\n}\n', "E_CMD_SHAPE copy: expected inputs 1-1, got 0"),
            ('step {\n out "out/x"\n cmd concat()\n}\n', "E_CMD_SHAPE concat: expected inputs 1-N, got 0"),
            ('step {\n out ["out/x", "out/y"]\n cmd write("")\n}\n', "E_CMD_SHAPE write: expected outputs 1, got 2"),
            ('step {\n out "out/x"\n depfile "out/y"\n cmd write("")\n}\n', "E_CMD_SHAPE write: depfile not allowed"),
            ('step {\n out "out/x"\n in "a"\n cmd preprocess()\n}\n', "E_CMD_SHAPE preprocess: depfile required"),
            ('step {\n out "out/x"\n in "a"\n cmd replace("", "x")\n}\n', "E_ARG cmd replace: empty pattern"),
            ('step {\n out "out/x"\n in "a"\n cmd indent(-1)\n}\n', "E_ARG cmd indent: negative"),
            ('step {\n out "out/x"\n cmd write()\n}\n', "E_ARITY cmd write: expected 1, got 0"),
            ('step {\n out "out/x"\n cmd write(1)\n}\n', "E_TYPE cmd write argument 1: expected str, got int"),
            ('step {\n out "out/x"\n cmd write(nope)\n}\n', "E_UNKNOWN_VAR nope"),
        ],
    )
    def test_errors(self, build_error, main, error):
        assert build_error(main, {"a": ""}) == error

    def test_rule_depth_64_is_allowed(self, build_error, session):
        main = """
rule r(n) {
    when n > 0 {
        use r(n - 1)
    }
}
use r(63)
default "@x"
phony x = []
"""
        res = session({"main.kiln": main}, "build")
        assert "ok ran=0" in res.log
        res = session({"main.kiln": main.replace("r(63)", "r(64)")}, "build")
        assert "E_RULE_RECURSION r" in res.log
