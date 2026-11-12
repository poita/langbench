"""Deep and large inputs must work and must not be quadratic."""

import time


def test_deep_parentheses(check):
    n = 3000
    assert check("(" * n + "1" + ")" * n + ";;") == ["- : int"]


def test_deep_nested_lists_and_tuples(check):
    n = 2000
    assert check("[" * n + "1" + "]" * n + ";;") == ["- : " + "int" + " list" * n]
    (line,) = check("(1, " * n + "2" + ")" * n + ";;")
    assert line.count("*") == n


def test_application_chain(check):
    n = 5000
    assert check("let k x y = x;; k " + "1 " * n + ";;")[1].startswith("error")
    assert check("fun f -> f " + "1 " * n + ";;") == [
        "- : (" + "int -> " * n + "'a) -> 'a"
    ]


def test_big_list_and_cons_chain(check):
    assert check("[" + "; ".join(["1"] * 100000) + "];;") == ["- : int list"]
    assert check("1 :: " * 2000 + "[];;") == ["- : int list"]


def test_thousand_parameters(check):
    params = " ".join(f"p{i}" for i in range(1000))
    (line,) = check(f"fun {params} -> p0;;")
    assert line.count("->") == 1000


def test_pair_tower_is_shared():
    # p40 has 2**40 leaves when printed, so it must never be expanded.
    from typeinfer import infer_program, run_deep

    src = "let pair x = (x, x);; let p0 = fun x -> x;;\n"
    for i in range(1, 41):
        src += f"let p{i} = pair p{i-1};;\n"
    src += "let r = fun a -> (p40, p40, a);;\n"
    start = time.time()
    results = run_deep(lambda: infer_program(src))
    assert all(r.ok for r in results)
    assert time.time() - start < 10


def test_many_toplevel_bindings(check):
    src = "".join(f"let v{i} = {i};;\n" for i in range(5000)) + "v4999;;"
    assert check(src)[-1] == "- : int"


def test_nested_let_chain(check):
    n = 3000
    src = "(" + "".join(f"let a{i} = a{i-1} in " if i else "let a0 = 1 in " for i in range(n)) + f"a{n-1});;"
    assert check(src) == ["- : int"]
