import pytest

from typeinfer import Inferencer, infer_program, infer_type, parse_program


def test_spec_example_1(check):
    src = """
let id = fun x -> x;;
let compose f g x = f (g x);;
compose;;
let rec len l = if null l then 0 else 1 + len (tl l);;
(id 1, id true, len [true]);;
fun f -> (f 1, f true);;
"""
    assert check(src) == [
        "id : 'a -> 'a",
        "compose : ('a -> 'b) -> ('c -> 'a) -> 'c -> 'b",
        "- : ('a -> 'b) -> ('c -> 'a) -> 'c -> 'b",
        "len : 'a list -> int",
        "- : int * bool * int",
        "error: unify",
    ]


def test_spec_example_2(check):
    src = """
let succ n = fun f x -> f (n f x);;
let add m n = fun f x -> m f (n f x);;
fun x -> x x;;
let g = id id;;
let id = fun x -> x;;
let g = id id;;
(g 1, g true);;
[fun p -> (snd p, fst p)];;
"""
    assert check(src) == [
        "succ : (('a -> 'b) -> 'c -> 'a) -> ('a -> 'b) -> 'c -> 'b",
        "add : ('a -> 'b -> 'c) -> ('a -> 'd -> 'b) -> 'a -> 'd -> 'c",
        "error: occurs",
        "error: unbound",
        "id : 'a -> 'a",
        "g : 'a -> 'a",
        "- : int * bool",
        "- : ('a * 'b -> 'b * 'a) list",
    ]


def test_spec_example_3(check):
    src = """
let map = 3;;
map;;
fun a b c -> let p = (a, b) in (fun x -> [x; c], p, fst p);;
let rec bad x = bad 1 + bad true;;
1 :: [true];;
"""
    assert check(src) == [
        "map : int",
        "- : int",
        "- : 'a -> 'b -> 'c -> ('c -> 'c list) * ('a * 'b) * 'a",
        "error: unify",
        "error: unify",
    ]


def test_empty_program(check):
    assert check("") == []
    assert check(" \n\t ") == []


@pytest.mark.parametrize(
    "src, expected",
    [
        ("fun x -> if true then (x, 0) else ([x], true);;", "error: occurs"),
        ("true + undefined;;", "error: unify"),
        ("undefined + true;;", "error: unbound"),
        ("(let rec f x = f in undefined);;", "error: occurs"),
        ("(let x = undefined in 1 + true);;", "error: unbound"),
        ("[1; true; undefined];;", "error: unify"),
        ("[undefined; 1; true];;", "error: unbound"),
        ("true = false;;", "error: unify"),
        ("(1, 2) = (1, 2);;", "error: unify"),
        ("fun x -> (x, 1) = (1, 1, 1);;", "error: unify"),
    ],
)
def test_error_kinds(check, src, expected):
    assert check(src) == [expected]


def test_failed_declaration_adds_nothing(check):
    assert check("let x = 1;; let x = true + 1;; x;;") == ["x : int", "error: unify", "- : int"]
    assert check("let y = 1 + true;; y;;") == ["error: unify", "error: unbound"]


def test_let_does_not_see_itself(check):
    assert check("let x = x + 1;;") == ["error: unbound"]
    assert check("let x = true;; let x = x && x;; x;;") == ["x : bool", "x : bool", "- : bool"]
    assert check("let rec f n = f;;") == ["error: occurs"]


def test_no_value_restriction(check):
    assert check("let id = fun x -> x;; let g = id id;; (g 1, g true);;") == [
        "id : 'a -> 'a", "g : 'a -> 'a", "- : int * bool"
    ]
    assert check("(let f = fun x -> x in (f 1, f true));;") == ["- : int * bool"]


def test_lambda_bound_is_monomorphic(check):
    assert check("fun f -> (f 1, f true);;") == ["error: unify"]


def test_letrec_is_monomorphic_inside(check):
    assert check("let rec f x = f 1 + f true;;") == ["error: unify"]
    assert check("let rec f x = if x then 0 else f (not x);; (f true);;") == [
        "f : bool -> int", "- : int"
    ]


def test_shadowing_builtins(check):
    assert check("let fst x = x;; fst 1;; let hd = true;; hd;;") == [
        "fst : 'a -> 'a", "- : int", "hd : bool", "- : bool"
    ]


def test_builtins(check):
    assert check("map;; fold;; not;; length;;") == [
        "- : ('a -> 'b) -> 'a list -> 'b list",
        "- : ('a -> 'b -> 'a) -> 'a -> 'b list -> 'a",
        "- : bool -> bool",
        "- : 'a list -> int",
    ]


def test_tuples_are_flat(check):
    assert check("(1, true, ());;") == ["- : int * bool * unit"]
    assert check("(fun p -> fst p + 1) (1, 2, 3);;") == ["error: unify"]


def test_many_variables_naming(check):
    params = " ".join(f"p{i}" for i in range(30))
    body = "(" + ", ".join(f"p{i}" for i in range(30)) + ")"
    (line,) = check(f"fun {params} -> {body};;")
    assert line.startswith("- : 'a -> 'b -> 'c")
    assert "'z -> 'a1 -> 'b1" in line


def test_infer_type_helper():
    assert infer_type("fun x -> x") == "'a -> 'a"


def test_inferencer_keeps_state():
    inf = Inferencer()
    results = [inf.check_decl(d) for d in parse_program("let x = 1;;")]
    assert results[0].ok and results[0].render() == "x : int"
    (d,) = parse_program("x + y;;")
    assert inf.check_decl(d).error == "unbound"
    assert infer_program("1;;")[0].type is not None
