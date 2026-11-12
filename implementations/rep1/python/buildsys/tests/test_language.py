"""KBL semantics, observed through the error a build reports."""

import pytest

from kiln import Builder, VirtualFS


def build_error(source: str, extra: dict[str, str] | None = None) -> str:
    fs = VirtualFS()
    fs.write(b"main.kiln", source.encode())
    for path, content in (extra or {}).items():
        fs.write(path.encode(), content.encode())
    result = Builder(fs).build()
    assert result.error is not None, "expected an error"
    return result.error.render().decode()


def written(expr: str) -> str:
    """Evaluate *expr* by writing it with a ``write`` step; returns the content."""
    fs = VirtualFS()
    fs.write(
        b"main.kiln",
        f'step {{\n out "out/x"\n cmd write("{{{expr}}}")\n}}\ndefault "out/x"\n'.encode(),
    )
    result = Builder(fs).build()
    assert result.error is None, result.error
    return fs.read(b"out/x").decode()


@pytest.mark.parametrize(
    "expr,value",
    [
        ("7 / 2", "3"),
        ("-7 / 2", "-3"),
        ("-7 % 3", "-1"),
        ("7 % -3", "1"),
        ('upper("abc") ~ "d"', "ABCd"),
        ("len([1, 2, 3])", "3"),
        ('substr("abcdef", -2, 5)', "ef"),
        ('substr("abcdef", 2, -1)', ""),
        ('join(split("a,,b", ","), "+")', "a++b"),
        ('stem("src/a.b.txt")', "a.b"),
        ('ext("src/.hidden")', ""),
        ('pathjoin("out", "", "a.txt")', "out/a.txt"),
        ('join(map(["a", "b"], "100%%-%"), " ")', "100%-a 100%-b"),
        ("join(sort([3, 1, 2]), \",\")", "1,2,3"),
        ("indexof([1, [2]], [2])", "1"),
        ("has([1], true)", "false"),
        ("[1, 2, 3][-1]", "3"),
        ('"abc"[1]', "b"),
        ("false && undefined_name", "false"),
        ("true || undefined_name", "true"),
        ('1 < "a"', "true"),
        ('[1, 2] < [1, 3]', "true"),
        ('"x" |> upper |> str', "X"),
        ("sum(range(5))", "10"),
        ("count(flatten([[1], 2, [3, 4]]))", "4"),
        ('join(filter(["a.c", "b.h", "d/e.c"], "*.c"), " ")', "a.c"),
        ('join(reject(["a.c", "b.h"], "*.c"), " ")', "b.h"),
        ('int("-012") + 1', "-11"),
        ("1 ++ 1" if False else "len(zip([1, 2], [3]))", "1"),
    ],
)
def test_expressions(expr, value):
    assert written(expr) == value


@pytest.mark.parametrize(
    "stmt,error",
    [
        ('let x = "a" + 1', "E_TYPE operator +: expected int, got str"),
        ('let x = 5["a"]', "E_TYPE index: expected int, got str"),
        ("let x = 5[0]", "E_TYPE index target: expected str|list, got int"),
        ("let x = [1][3]", "E_ARG fn index: out of range"),
        ("let x = upper(1, 2)", "E_ARITY fn upper: expected 1, got 2"),
        ("let x = pathjoin()", "E_ARITY fn pathjoin: expected 1-8, got 0"),
        ("let x = nope(undefined)", "E_UNKNOWN_FUNC nope"),
        ("let x = upper(undefined, 2)", "E_UNKNOWN_VAR undefined"),
        ("let x = 1 / 0", "E_DIV_ZERO"),
        ('let x = "{[1]}"', "E_INTERP list"),
        ("let x = 1\nlet x = 2", "E_REDEFINE x"),
        ("set y = 1", "E_SET_UNDEFINED y"),
        ('abort "stop {1 + 1}"', "E_ABORT stop 2"),
        ('let x = filter([1], "")', "E_ARG fn filter: bad pattern"),
        ('let x = join([[1]], ",")', "E_TYPE fn join element 0: expected str|int, got list"),
        ("let x = first([])", "E_ARG fn first: empty list"),
        ("when 1 {\n}", "E_TYPE when condition: expected bool, got int"),
        ("each x in 1 {\n}", "E_TYPE each subject: expected list, got int"),
        ("default 3", "E_TYPE default: expected strlist, got int"),
        ('include "nope.kiln"', "E_INCLUDE_MISSING nope.kiln"),
        ('include "main.kiln"', "E_INCLUDE_CYCLE main.kiln"),
        ('include "../x"', "E_BAD_PATH ../x"),
        ('phony a = "@@"', "E_BAD_PATH @@"),
        ('phony a = []\nphony a = []', "E_DUP_PHONY a"),
        ("use nothing()", "E_UNKNOWN_RULE nothing"),
    ],
)
def test_errors(stmt, error):
    assert build_error(stmt + "\n") == error


def test_scoping_and_set():
    src = (
        "let x = 1\n"
        "when true {\n let x = 5\n set x = 6\n}\n"
        "each i, v in [10, 20] {\n set x = x + v\n}\n"
        'step {\n out "out/x"\n cmd write("{x}")\n}\ndefault "out/x"\n'
    )
    fs = VirtualFS()
    fs.write(b"main.kiln", src.encode())
    assert Builder(fs).build().ok
    assert fs.read(b"out/x") == b"31"


def test_rule_scope_is_defining_scope_by_reference():
    src = (
        "let tag = 'a'\n"
        "rule r(name, suffix = tag ~ name) {\n"
        '  step {\n    out "out/{name}{suffix}"\n    cmd write(tag)\n  }\n'
        "}\n"
        "set tag = 'b'\n"
        "use r('x')\nuse r(suffix = '+', name = 'y')\n"
        'default ["out/xbx", "out/y+"]\n'
    )
    fs = VirtualFS()
    fs.write(b"main.kiln", src.encode())
    assert Builder(fs).build().ok
    assert fs.read(b"out/xbx") == b"b"


@pytest.mark.parametrize(
    "use,error",
    [
        ("use r(1, 2, 3)", "E_ARITY rule r: expected 2, got 3"),
        ("use r(1, c = 2)", "E_ARG rule r: unknown argument c"),
        ("use r(1, a = 2)", "E_ARG rule r: duplicate argument a"),
        ("use r(1)", "E_ARG rule r: missing argument b"),
    ],
)
def test_use_errors(use, error):
    assert build_error("rule r(a, b) {\n}\n" + use + "\n") == error


def test_rule_recursion_limit():
    assert build_error("rule r(n) {\n use r(n + 1)\n}\nuse r(0)\n") == "E_RULE_RECURSION r"


def test_glob_sees_only_source_files(session):
    files = {
        "main.kiln": (
            'step {\n out "out/list"\n cmd write(join(glob("**/*.txt"), " "))\n}\n'
            'default "out/list"\n'
        ),
        "b.txt": "",
        "a.txt": "",
        "d/c.txt": "",
        "out/old.txt": "",
        ".kiln-state": "",
    }
    _, fs = session(files, "build\n")
    assert fs.read(b"out/list") == b"a.txt b.txt d/c.txt"
