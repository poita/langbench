/**
 * Whole-program entry points.
 */
module typeinfer.program;

import typeinfer.infer;
import typeinfer.lexer : SyntaxError;
import typeinfer.parser;

/// The result of checking a whole program.
struct Report
{
    /// One result per declaration, in order. Holds the declarations before a syntax error, if any.
    DeclResult[] decls;
    /// Non-empty if the source could not be parsed past the last entry of `decls`.
    string syntaxError;

    /// The expected program output: one line per declaration, each ending in `\n`.
    string output() const @safe 
    {
        import std.array : appender;
        auto o = appender!string();
        foreach (ref d; decls)
        {
            o ~= d.toString;
            o ~= '\n';
        }
        return o[];
    }
}

/**
 * Parses and type-checks `source`, declaration by declaration.
 * Never throws for bad syntax; see `Report.syntaxError`.
 */
Report checkSource(string source) @safe 
{
    Report rep;
    auto parser = new Parser(source);
    auto inf = new Inferencer;
    try
    {
        while (!parser.atEnd) rep.decls ~= inf.check(parser.parseDecl());
    }
    catch (SyntaxError e)
    {
        rep.syntaxError = e.msg;
    }
    return rep;
}

/// Convenience: the program output for `source` (see $(LREF Report.output)).
string typeCheck(string source) @safe 
{
    return checkSource(source).output;
}

@safe unittest
{
    immutable src = "let id = fun x -> x;;
let compose f g x = f (g x);;
compose;;
let rec len l = if null l then 0 else 1 + len (tl l);;
(id 1, id true, len [true]);;
fun f -> (f 1, f true);;
";
    assert(typeCheck(src) == "id : 'a -> 'a
compose : ('a -> 'b) -> ('c -> 'a) -> 'c -> 'b
- : ('a -> 'b) -> ('c -> 'a) -> 'c -> 'b
len : 'a list -> int
- : int * bool * int
error: unify
");
}

@safe unittest
{
    immutable src = "let succ n = fun f x -> f (n f x);;
let add m n = fun f x -> m f (n f x);;
fun x -> x x;;
let g = id id;;
let id = fun x -> x;;
let g = id id;;
(g 1, g true);;
[fun p -> (snd p, fst p)];;
";
    assert(typeCheck(src) == "succ : (('a -> 'b) -> 'c -> 'a) -> ('a -> 'b) -> 'c -> 'b
add : ('a -> 'b -> 'c) -> ('a -> 'd -> 'b) -> 'a -> 'd -> 'c
error: occurs
error: unbound
id : 'a -> 'a
g : 'a -> 'a
- : int * bool
- : ('a * 'b -> 'b * 'a) list
");
}

@safe unittest
{
    immutable src = "let map = 3;;
map;;
fun a b c -> let p = (a, b) in (fun x -> [x; c], p, fst p);;
let rec bad x = bad 1 + bad true;;
1 :: [true];;
";
    assert(typeCheck(src) == "map : int
- : int
- : 'a -> 'b -> 'c -> ('c -> 'c list) * ('a * 'b) * 'a
error: unify
error: unify
");
}

@safe unittest
{
    assert(typeCheck("") == "");
    assert(typeCheck(" \n\t ") == "");
    // Types of builtins, passing and partially applying them.
    assert(typeCheck("map;; fold;; map not;; hd [fst];;")
            == "- : ('a -> 'b) -> 'a list -> 'b list\n"
            ~ "- : ('a -> 'b -> 'a) -> 'a -> 'b list -> 'a\n"
            ~ "- : bool list -> bool list\n"
            ~ "- : 'a * 'b -> 'a\n");
}

@safe unittest
{
    // Syntax errors: earlier declarations are still reported.
    auto r = checkSource("1;; let = ;; 2;;");
    assert(r.decls.length == 1 && r.syntaxError.length);
    assert(r.output == "- : int\n");
}

@safe unittest
{
    // Tuples of different arity differ; tuples are not nested pairs.
    assert(typeCheck("(1, 2, 3);; [(1, 2); (1, 2, 3)];; (1, (2, 3)) = (1, 2, 3);;")
            == "- : int * int * int\nerror: unify\nerror: unify\n");
}

@safe unittest
{
    // Many type variables are named 'a .. 'z, 'a1, ...
    string params, tup;
    foreach (i; 0 .. 30)
    {
        import std.conv : to;
        params ~= " p" ~ i.to!string;
        tup ~= (i ? ", p" : "p") ~ i.to!string;
    }
    auto out_ = typeCheck("fun" ~ params ~ " -> (" ~ tup ~ ");;");
    import std.algorithm : canFind;
    assert(out_.canFind("'z -> 'a1 -> 'b1 -> 'c1 -> 'd1 -> "));
}

@safe unittest
{
    // Types are shared, not expanded: unifying two big instances of a tower is fast.
    string src = "let pair x = (x, x);; let p0 = fun x -> x;;";
    import std.conv : to;
    enum n = 14; // printed result has 2^14 leaves
    foreach (i; 1 .. n + 1)
        src ~= " let p" ~ i.to!string ~ " = pair p" ~ (i - 1).to!string ~ ";;";
    src ~= " [p" ~ n.to!string ~ "; p" ~ n.to!string ~ "];;";
    auto r = checkSource(src);
    assert(r.decls.length == 2 + n + 1 && r.decls[$ - 1].ok);
}

unittest
{
    // Deeply nested input works given a large enough stack.
    import core.thread : Thread;
    import std.array : replicate;
    string result;
    auto t = new Thread({
        enum depth = 3000;
        auto src = "(".replicate(depth) ~ "fun x -> x" ~ ")".replicate(depth) ~ ";;"
            ~ "let rec f x = " ~ "let y = x in ".replicate(depth) ~ "y;;";
        result = typeCheck(src);
    }, 256 * 1024 * 1024);
    t.start();
    t.join();
    assert(result == "- : 'a -> 'a\nf : 'a -> 'a\n");
}
