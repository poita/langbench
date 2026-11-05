/// Unit tests for typeinfer.parser.
module parser_test;

import std.exception : assertThrown;
import typeinfer.ast;
import typeinfer.errors;
import typeinfer.lexer;
import typeinfer.parser;

private Program parseText(string src)
{
    return parse(tokenize(src, new Interner));
}

/// Renders expression `i` as a fully parenthesised S-expression.
private string show(ref const Program p, int i)
{
    import std.conv : to;
    import std.format : format;

    immutable e = p.exprs[i];
    final switch (e.kind)
    {
    case ExprKind.intLit:     return "n";
    case ExprKind.boolLit:    return e.a ? "true" : "false";
    case ExprKind.unitLit:    return "()";
    case ExprKind.variable:   return "v" ~ e.a.to!string;
    case ExprKind.app:        return "(" ~ show(p, e.a) ~ " " ~ show(p, e.b) ~ ")";
    case ExprKind.fun:        return "(fun v" ~ e.a.to!string ~ " " ~ show(p, e.b) ~ ")";
    case ExprKind.ifThenElse: return "(if " ~ show(p, e.a) ~ " " ~ show(p, e.b) ~ " " ~ show(p, e.c) ~ ")";
    case ExprKind.let:        return "(let v" ~ e.a.to!string ~ " " ~ show(p, e.b) ~ " " ~ show(p, e.c) ~ ")";
    case ExprKind.letRec:     return "(letrec v" ~ e.a.to!string ~ " " ~ show(p, e.b) ~ " " ~ show(p, e.c) ~ ")";
    case ExprKind.cons:       return "(:: " ~ show(p, e.a) ~ " " ~ show(p, e.b) ~ ")";
    case ExprKind.binary:     return format("(%s %s %s)", e.op, show(p, e.a), show(p, e.b));
    case ExprKind.tuple:
    case ExprKind.list:
        string r = e.kind == ExprKind.tuple ? "(tuple" : "(list";
        foreach (k; 0 .. e.b)
            r ~= " " ~ show(p, p.children[e.a + k]);
        return r ~ ")";
    }
}

private string showOnly(string src)
{
    auto p = parseText(src);
    assert(p.decls.length == 1);
    return show(p, p.decls[0].expr);
}

unittest // no declarations
{
    assert(parseText("").decls.length == 0);
    assert(parseText("  \n ").decls.length == 0);
}

unittest // declaration kinds and names
{
    auto p = parseText("let x = 1;; let rec f a = f a;; x;;");
    assert(p.decls.length == 3);
    assert(p.decls[0].kind == DeclKind.let && p.decls[0].name == 0);
    assert(p.decls[1].kind == DeclKind.letRec && p.decls[1].name == 1);
    assert(p.decls[2].kind == DeclKind.expr);
}

unittest // operator precedence and associativity
{
    assert(showOnly("1 + 2 * 3;;") == "(add n (mul n n))");
    assert(showOnly("1 - 2 - 3;;") == "(sub (sub n n) n)");
    assert(showOnly("a < b && c || d;;") == "(or (and (lt v0 v1) v2) v3)");
    assert(showOnly("f x + g y * 2;;") == "(add (v0 v1) (mul (v2 v3) n))");
}

unittest // application is left-associative
{
    assert(showOnly("f x y;;") == "((v0 v1) v2)");
}

unittest // :: is right-associative and binds looser than +
{
    assert(showOnly("1 :: f x :: l;;") == "(:: n (:: (v0 v1) v2))");
    assert(showOnly("1 + 2 :: l;;") == "(:: (add n n) v0)");
}

unittest // let f x y = e is sugar for nested funs
{
    auto p = parseText("let f x y = x;;");
    assert(show(p, p.decls[0].expr) == "(fun v1 (fun v2 v1))");
    p = parseText("fun a b c -> a;;");
    assert(show(p, p.decls[0].expr) == "(fun v0 (fun v1 (fun v2 v0)))");
}

unittest // bodies of fun / if / let extend as far right as possible, up to , ; ) ]
{
    assert(showOnly("fun x -> x + 1;;") == "(fun v0 (add v0 n))");
    assert(showOnly("(fun x -> x, 1);;") == "(tuple (fun v0 v0) n)");
    assert(showOnly("[fun x -> x; fun y -> 1];;") == "(list (fun v0 v0) (fun v1 n))");
    assert(showOnly("(let y = 1 in y, 2);;") == "(tuple (let v0 n v0) n)");
    assert(showOnly("if a then b else c + 1;;") == "(if v0 v1 (add v2 n))");
}

unittest // tuples, lists, unit, parentheses
{
    assert(showOnly("(1, 2, 3);;") == "(tuple n n n)");
    assert(showOnly("((1, 2), 3);;") == "(tuple (tuple n n) n)");
    assert(showOnly("();;") == "()");
    assert(showOnly("[];;") == "(list)");
    assert(showOnly("[1; 2];;") == "(list n n)");
    assert(showOnly("((1));;") == "n");
}

unittest // let-expression operands need parentheses; bare let is a binding
{
    auto p = parseText("(let x = 1 in x);;");
    assert(p.decls[0].kind == DeclKind.expr);
    assertThrown!SyntaxError(parseText("1 + let x = 1 in x;;"));
}

unittest // malformed programs
{
    assertThrown!SyntaxError(parseText("let x = ;;"));
    assertThrown!SyntaxError(parseText("let rec f = 1;;"));
    assertThrown!SyntaxError(parseText("1 + 2"));
    assertThrown!SyntaxError(parseText("(1, );;"));
    assertThrown!SyntaxError(parseText("fun -> 1;;"));
    assertThrown!SyntaxError(parseText("[1; ];;"));
}

unittest // a comparison is non-associative: the second operator is a syntax error
{
    assertThrown!SyntaxError(parseText("1 < 2 < 3;;"));
}
