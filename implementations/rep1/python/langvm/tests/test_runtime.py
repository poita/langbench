"""Programs that compile and run: output, evaluation order, panics."""

import pytest


def test_hello_two_modules(run):
    src = (
        "@module main\nuse util;\nfn main() { print(util::greet(\"world\")); }\n"
        "@module util\npub fn greet(who: Str) -> Str { \"hello, \" ++ who }\n"
    )
    assert run(src) == "hello, world\n"


def test_panic_continues_the_last_output_line(run_main):
    assert run_main('emit("a"); panic("boom");') == "apanic: boom\n"


@pytest.mark.parametrize(
    "expr, message",
    [
        ("1 / (1 - 1)", "divide by zero"),
        ("1 % (1 - 1)", "modulo by zero"),
        ("1 << 64", "shift amount out of range"),
        ("1 >> (0 - 1)", "shift amount out of range"),
        ("[1][1]", "index out of bounds"),
        ("charAt(\"ab\", 2)", "index out of bounds"),
        ("#[1: 2][3]", "missing key"),
        ("unwrap(parseInt(\"x\"))", "unwrap of None"),
        ("pop(slice([1], 1, 1))", "empty list"),
        ("ord(chr(55296))", "invalid char code"),
        ("truncToInt(nanF())", "float out of integer range"),
        ("fmt(\"{\", [])", "bad format"),
        ("fmt(\"{} {}\", [\"a\"])", "bad format"),
        ("powI(2, 0 - 1)", "negative exponent"),
        ("strSplit(\"a\", \"\")", "empty separator"),
        ("showIntRadix(1, 1)", "radix out of range"),
        ("showFloatAt(1.0, 18)", "digits out of range"),
    ],
)
def test_panics(run_main, expr, message):
    out = run_main(f"print(\"start\"); let v = {expr}; print(\"never\");")
    assert out == f"start\npanic: {message}\n"


def test_call_stack_limit(run_main):
    extra = "fn down(n: Int) -> Int { if n == 0 { return 0; } down(n - 1) + 1 }"
    assert run_main("print(showInt(down(19998)));", extra) == "19998\n"
    assert run_main("print(showInt(down(19999)));", extra) == "panic: call stack overflow\n"


def test_early_return_from_inside_an_expression(run_main):
    extra = "enum E { A, B(Int) }\nfn f(e: E) -> Int { 10 + match e { A -> { return 5; }, B(n) -> n } }"
    assert run_main("print(showInt(f(A))); print(showInt(f(B(4))));", extra) == "5\n14\n"


def test_break_inside_expression_keeps_the_stack_clean(run_main):
    body = """
    var t = 0;
    for i in 0 .. 5 { t = t + 1 + match i { 3 -> { break; }, _ -> 0 }; }
    print(showInt(t));
    """
    assert run_main(body) == "3\n"


def test_struct_fields_evaluate_in_written_order(run_main):
    extra = "struct P { a: Int, b: Int }\nfn n(s: Str, v: Int) -> Int { emit(s); v }"
    body = 'let p = P.{ b: n("b", 2), a: n("a", 1) }; print(" " ++ showInt(p.a) ++ showInt(p.b));'
    assert run_main(body, extra) == "ba 12\n"


def test_wrapping_integer_arithmetic(run_main):
    body = """
    print(showInt(intMax() + 1));
    print(showInt(intMin() / -1));
    print(showInt(-7 / 2) ++ " " ++ showInt(-7 % 2) ++ " " ++ showInt(7 % -2));
    print(showInt(-16 >> 2) ++ " " ++ showInt(1 << 63));
    """
    assert run_main(body) == (
        "-9223372036854775808\n-9223372036854775808\n-3 -1 1\n-4 -9223372036854775808\n"
    )


def test_closures_capture_by_value_but_share_lists(run_main):
    body = """
    var base = 1;
    let f = |d: Int| base + d;
    base = 100;
    print(showInt(f(5)));
    let shared = [1];
    let grow = || push(shared, 2);
    grow();
    print(showInt(listLen(shared)));
    var fs: [fn() -> Int] = listNew();
    for i in 0 .. 3 { push(fs, || i * i); }
    print(strJoin(listMap(fs, |g| showInt(g())), ","));
    """
    assert run_main(body) == "6\n2\n0,1,4\n"


def test_nested_lambda_captures_through_intermediate(run_main):
    body = """
    let a = 2;
    let mk = |b: Int| |c: Int| a * 100 + b * 10 + c;
    print(showInt(mk(3)(4)));
    """
    assert run_main(body) == "234\n"


def test_for_over_list_sees_appended_elements(run_main):
    body = """
    var xs = [1, 2];
    var n = 0;
    for x in xs { if n < 3 { push(xs, x * 10); } n = n + 1; }
    print(strJoin(listMap(xs, |v| showInt(v)), ","));
    """
    assert run_main(body) == "1,2,10,20,100\n"


def test_map_keeps_insertion_order_and_ignores_it_for_equality(run_main):
    body = """
    var m = #["a": 1];
    m["b"] = 2;
    m["a"] = 3;
    mapDel(m, "a");
    m["a"] = 4;
    print(strJoin(keysOf(m), ""));
    print(showBool(#[1: 2, 3: 4] == #[3: 4, 1: 2]));
    """
    assert run_main(body) == "ba\ntrue\n"


def test_nan_is_never_equal_even_inside_containers(run_main):
    body = """
    let n = nanF();
    print(showBool(n == n) ++ showBool([n] == [n]) ++ showBool((n, 1) == (n, 1)));
    """
    assert run_main(body) == "falsefalsefalse\n"


def test_traits_defaults_generic_bounds_and_char_vs_str(run_main):
    extra = """
trait Show { fn show(self) -> Str; fn twice(self) -> Str { self.show() ++ self.show() } }
impl Show for Char { fn show(self) -> Str { "c" ++ showChar(self) } }
impl Show for Str { fn show(self) -> Str { "s" ++ self } }
impl<T: Show> Show for [T] { fn show(self) -> Str { strJoin(listMap(self, |x| x.show()), "|") } }
fn gen<T: Show>(x: T) -> Str { x.twice() }
"""
    body = 'print(gen(\'x\')); print(gen("x")); print(gen(["a", "b"])); print(Show::show(\'q\'));'
    assert run_main(body, extra) == "cxcx\nsxsx\nsa|sbsa|sb\ncq\n"


def test_match_patterns(run_main):
    extra = "struct P { a: Int, b: Str }"
    body = """
    match [1, 2, 3] { [a, ..rest] -> print(showInt(a) ++ showInt(listLen(rest))), [] -> print("e"), }
    let P.{ a, .. } = P.{ a: 7, b: "z" };
    print(showInt(a));
    match (1, "x") { (1, s) when s == "y" -> print("no"), (1, s) -> print(s), (_, _) -> print("other"), }
    match 'c' { 'a' -> print("a"), 'c' -> print("c"), _ -> print("?") }
    match -5 { -5 -> print("neg"), _ -> print("pos") }
    """
    assert run_main(body, extra) == "12\n7\nx\nc\nneg\n"


def test_sort_by_is_stable_merge_sort_with_exact_comparator_calls(run_main):
    body = """
    let calls = [0];
    let sorted = sortBy([(2, "a"), (1, "b"), (2, "c"), (1, "d")], |x, y| { calls[0] = calls[0] + 1; cmpI(fst(x), fst(y)) });
    print(strJoin(listMap(sorted, |p| snd(p)), "") ++ " " ++ showInt(calls[0]));
    """
    assert run_main(body) == "bdac 5\n"


def test_prelude_option_can_be_shadowed(run):
    src = "@module main\nenum Option<T> { Some(T), None, Extra }\nfn main() { let o: Option<Int> = Extra; match o { Extra -> print(\"x\"), _ -> print(\"y\") } }\n"
    assert run(src) == "x\n"


def test_trait_path_resolution_prefers_own_then_sorted_imports(run):
    src = (
        "@module main\nuse za;\nuse ab;\nfn main() { print(Shape::name(1)); }\n"
        "@module za\npub trait Shape { fn name(self) -> Str; }\nimpl Shape for Int { fn name(self) -> Str { \"za\" } }\n"
        "@module ab\npub trait Shape { fn name(self) -> Str; }\nimpl Shape for Str { fn name(self) -> Str { \"ab\" } }\n"
    )
    # `Shape::name` means ab's trait (smaller alias), which has no impl for Int
    assert run(src) == "error: unsatisfied-bound at 3:26\n"


def test_higher_order_builtins_count_frames_exactly(run_main):
    extra = "fn walk(n: Int) -> Int { if n == 0 { return 0; } listMap([n], |x| walk(x - 1) + 1)[0] }"
    assert run_main("print(showInt(walk(9000)));", extra) == "9000\n"
    assert run_main("print(showInt(walk(30000)));", extra) == "panic: call stack overflow\n"
