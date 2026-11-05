/// Unit tests for the end-to-end type checker (typeinfer.checker, infer).
module checker_test;

import std.algorithm : map;
import std.array : array, join;
import std.exception : assertThrown;
import typeinfer;

/// Output lines for `src`, without the trailing newlines.
private string[] run(string src)
{
    import std.string : splitLines;

    return inferProgram(src).splitLines;
}

private void check(string src, string[] expected, string file = __FILE__, size_t line = __LINE__)
{
    auto got = run(src);
    assert(got == expected, "line " ~ line.stringof ~ ": got " ~ got.join(" | "));
}

unittest // empty program
{
    assert(inferProgram("") == "");
    assert(inferProgram("  \n") == "");
}

unittest // spec examples
{
    check(`
let id = fun x -> x;;
let compose f g x = f (g x);;
compose;;
let rec len l = if null l then 0 else 1 + len (tl l);;
(id 1, id true, len [true]);;
fun f -> (f 1, f true);;`,
        ["id : 'a -> 'a",
         "compose : ('a -> 'b) -> ('c -> 'a) -> 'c -> 'b",
         "- : ('a -> 'b) -> ('c -> 'a) -> 'c -> 'b",
         "len : 'a list -> int",
         "- : int * bool * int",
         "error: unify"]);
    check(`
let succ n = fun f x -> f (n f x);;
let add m n = fun f x -> m f (n f x);;
fun x -> x x;;
let g = id id;;
let id = fun x -> x;;
let g = id id;;
(g 1, g true);;
[fun p -> (snd p, fst p)];;`,
        ["succ : (('a -> 'b) -> 'c -> 'a) -> ('a -> 'b) -> 'c -> 'b",
         "add : ('a -> 'b -> 'c) -> ('a -> 'd -> 'b) -> 'a -> 'd -> 'c",
         "error: occurs", "error: unbound",
         "id : 'a -> 'a", "g : 'a -> 'a",
         "- : int * bool", "- : ('a * 'b -> 'b * 'a) list"]);
    check(`
let map = 3;;
map;;
fun a b c -> let p = (a, b) in (fun x -> [x; c], p, fst p);;
let rec bad x = bad 1 + bad true;;
1 :: [true];;`,
        ["map : int", "- : int",
         "- : 'a -> 'b -> 'c -> ('c -> 'c list) * ('a * 'b) * 'a",
         "error: unify", "error: unify"]);
}

unittest // built-ins
{
    check("not;; fst;; snd;; hd;; tl;; null;; length;; map;; fold;;",
        ["- : bool -> bool", "- : 'a * 'b -> 'a", "- : 'a * 'b -> 'b",
         "- : 'a list -> 'a", "- : 'a list -> 'a list", "- : 'a list -> bool",
         "- : 'a list -> int", "- : ('a -> 'b) -> 'a list -> 'b list",
         "- : ('a -> 'b -> 'a) -> 'a -> 'b list -> 'a"]);
}

unittest // operators
{
    check("1 + 2;; 1 < 2;; true && false;; true = false;;",
        ["- : int", "- : bool", "- : bool", "error: unify"]);
    check("fun x -> x + 1;; fun x y -> x < y;; fun a -> a && true;;",
        ["- : int -> int", "- : int -> int -> bool", "- : bool -> bool"]);
}

unittest // value restriction does not exist; lambda-bound variables are monomorphic
{
    check("let g = id;;", ["error: unbound"]);
    check("let id = fun x -> x;; let g = id id;; (g 1, g true);;",
        ["id : 'a -> 'a", "g : 'a -> 'a", "- : int * bool"]);
    check("fun f -> (f 1, f true);;", ["error: unify"]);
    check("let rec f x = f 1 + f true;;", ["error: unify"]);
}

unittest // error kinds and their order
{
    check("fun x -> x x;;", ["error: occurs"]);
    check("undefined;;", ["error: unbound"]);
    check("fun x -> if true then (x, 0) else ([x], true);;", ["error: occurs"]);
    check("true + undefined;;", ["error: unify"]);
    check("undefined + true;;", ["error: unbound"]);
    check("1 :: 2 :: undefined;;", ["error: unbound"]);
    check("(1, 2) = (1, 2, 3);;", ["error: unify"]);
}

unittest // a failed declaration adds nothing; later ones continue
{
    check("let x = 1 + true;; x;; let y = 2;; y;;",
        ["error: unify", "error: unbound", "y : int", "- : int"]);
    check("let x = 1;; let x = true + 1;; x;;",
        ["x : int", "error: unify", "- : int"]);
}

unittest // shadowing built-ins and non-recursive let
{
    check("let not = fun x -> x + 1;; not 1;;", ["not : int -> int", "- : int"]);
    check("let x = 1;; (let x = x + 1 in x);; let y = y;;",
        ["x : int", "- : int", "error: unbound"]);
    check("let rec f x = f;;", ["error: occurs"]);
}

unittest // tuples of different arity are distinct types
{
    check("[(1, 2); (1, 2, 3)];; [(1, 2, 3); (1, (2, 3))];;", ["error: unify", "error: unify"]);
    check("(1, true, ());;", ["- : int * bool * unit"]);
    check("(fun x -> x, 1);;", ["- : ('a -> 'a) * int"]);
}

unittest // TypeChecker.check returns structured results and keeps its environment
{
    auto tc = new TypeChecker;
    auto r = tc.check("let f x = x;; f;; f + 1;;");
    assert(r.length == 3);
    assert(r[0].ok && r[0].kind == DeclKind.let && r[0].name == "f" && r[0].type == "'a -> 'a");
    assert(r[1].ok && r[1].kind == DeclKind.expr && r[1].toString == "- : 'a -> 'a");
    assert(!r[2].ok && r[2].error == ErrorKind.unify && r[2].toString == "error: unify");
    assert(tc.check("f 1;;")[0].type == "int");
}

unittest // large inputs: long lists, deep nesting, many declarations
{
    import std.array : appender, replicate;
    import std.conv : to;

    runWithLargeStack({
        auto list = "[" ~ "1; ".replicate(50_000) ~ "1];;";
        assert(inferProgram(list) == "- : int list\n");

        auto nested = "(".replicate(3000) ~ "1" ~ ")".replicate(3000) ~ ";;";
        assert(inferProgram(nested) == "- : int\n");

        auto lets = appender!string;
        lets ~= "(";
        foreach (i; 0 .. 3000)
            lets ~= "let x" ~ i.to!string ~ " = " ~ (i ? "x" ~ (i - 1).to!string : "0") ~ " in ";
        lets ~= "x2999);;";
        assert(inferProgram(lets.data) == "- : int\n");

        auto many = appender!string;
        foreach (i; 0 .. 5000)
            many ~= "let v" ~ i.to!string ~ " = fun x -> x;;\n";
        many ~= "v4999 v0;;";
        auto out_ = inferProgram(many.data);
        assert(out_[$ - 13 .. $] == "- : 'a -> 'a\n");
    });
}

unittest // syntax errors surface as SyntaxError
{
    assertThrown!SyntaxError(inferProgram("let = 1;;"));
    assertThrown!SyntaxError(inferProgram("1 + "));
}

unittest // runWithLargeStack propagates exceptions
{
    assertThrown!Exception(runWithLargeStack({ throw new Exception("boom"); }));
}
