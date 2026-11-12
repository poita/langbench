/**
 * Recursive-descent parser for the grammar in the specification.
 *
 * Precedence, loosest to tightest: `let`/`fun`/`if`, `||`, `&&`, comparison,
 * `::`, `+ -`, `* /`, application. Parsing is recursive, so very deeply nested
 * input needs a correspondingly deep call stack.
 */
module typeinfer.parser;

import typeinfer.ast;
import typeinfer.lexer;

/// Parses declarations one at a time from source text.
final class Parser
{
    private string src;
    private Token[] toks;
    private size_t pos;

    /// Tokenises `source` and positions the parser at its first declaration.
    this(string source) @safe nothrow
    {
        src = source;
        toks = tokenize(source);
    }

    /// True once all declarations have been consumed.
    bool atEnd() const @safe nothrow @nogc { return cur.kind == Tok.eof; }

    /// Parses the next declaration (including its terminating `;;`).
    /// Throws $(REF SyntaxError, typeinfer.lexer) on malformed input.
    Decl parseDecl() @safe 
    {
        Decl d;
        if (cur.kind == Tok.kwLet)
        {
            advance();
            d.isRec = accept(Tok.kwRec);
            d.name = expectIdent();
            d.expr = parseLetRhs(d.isRec);
        }
        else
        {
            d.expr = parseExpr();
        }
        expect(Tok.semiSemi, "';;'");
        return d;
    }

    // -- token helpers ------------------------------------------------------

    private ref const(Token) cur() const @safe nothrow @nogc { return toks[pos]; }

    private void advance() @safe nothrow @nogc
    {
        if (toks[pos].kind != Tok.eof) ++pos;
    }

    private bool accept(Tok k) @safe nothrow @nogc
    {
        if (cur.kind != k) return false;
        advance();
        return true;
    }

    private SyntaxError fail(string what) @safe const
    {
        return new SyntaxError("syntax error at offset " ~ itoa(cur.start) ~ ": expected " ~ what, cur.start);
    }

    private void expect(Tok k, string what) @safe 
    {
        if (!accept(k)) throw fail(what);
    }

    private string expectIdent() @safe 
    {
        if (cur.kind != Tok.ident) throw fail("identifier");
        auto s = src[cur.start .. cur.end];
        advance();
        return s;
    }

    // -- grammar ------------------------------------------------------------

    /// After `let [rec] name`: parameters, `=`, and the right-hand side expression.
    /// Returns the right-hand side, wrapped in a `Lam` if there are parameters.
    private Expr parseLetRhs(bool isRec) @safe 
    {
        string[] params;
        while (cur.kind == Tok.ident) params ~= expectIdent();
        if (isRec && params.length == 0) throw fail("parameter");
        expect(Tok.eq, "'='");
        auto rhs = parseExpr();
        return params.length ? new Lam(params, rhs) : rhs;
    }

    private Expr parseExpr() @safe 
    {
        switch (cur.kind)
        {
            case Tok.kwLet:
            {
                advance();
                immutable isRec = accept(Tok.kwRec);
                auto name = expectIdent();
                auto rhs = parseLetRhs(isRec);
                expect(Tok.kwIn, "'in'");
                auto body_ = parseExpr();
                return new Let(name, isRec, rhs, body_);
            }
            case Tok.kwFun:
            {
                advance();
                string[] params;
                while (cur.kind == Tok.ident) params ~= expectIdent();
                if (params.length == 0) throw fail("parameter");
                expect(Tok.arrow, "'->'");
                return new Lam(params, parseExpr());
            }
            case Tok.kwIf:
            {
                advance();
                auto c = parseExpr();
                expect(Tok.kwThen, "'then'");
                auto t = parseExpr();
                expect(Tok.kwElse, "'else'");
                auto e = parseExpr();
                return new If(c, t, e);
            }
            default:
                return parseOr();
        }
    }

    private Expr parseOr() @safe 
    {
        auto l = parseAnd();
        while (cur.kind == Tok.orOr)
        {
            advance();
            l = new Binary(BinOp.or, l, parseAnd());
        }
        return l;
    }

    private Expr parseAnd() @safe 
    {
        auto l = parseCmp();
        while (cur.kind == Tok.andAnd)
        {
            advance();
            l = new Binary(BinOp.and, l, parseCmp());
        }
        return l;
    }

    private Expr parseCmp() @safe 
    {
        auto l = parseCons();
        BinOp op;
        switch (cur.kind)
        {
            case Tok.eq: op = BinOp.eq; break;
            case Tok.lt: op = BinOp.lt; break;
            case Tok.gt: op = BinOp.gt; break;
            case Tok.le: op = BinOp.le; break;
            case Tok.ge: op = BinOp.ge; break;
            default: return l;
        }
        advance();
        return new Binary(op, l, parseCons());
    }

    private Expr parseCons() @safe 
    {
        auto h = parseAdd();
        if (cur.kind == Tok.colonColon)
        {
            advance();
            return new Cons(h, parseCons());
        }
        return h;
    }

    private Expr parseAdd() @safe 
    {
        auto l = parseMul();
        for (;;)
        {
            BinOp op;
            if (cur.kind == Tok.plus) op = BinOp.add;
            else if (cur.kind == Tok.minus) op = BinOp.sub;
            else return l;
            advance();
            l = new Binary(op, l, parseMul());
        }
    }

    private Expr parseMul() @safe 
    {
        auto l = parseApp();
        for (;;)
        {
            BinOp op;
            if (cur.kind == Tok.star) op = BinOp.mul;
            else if (cur.kind == Tok.slash) op = BinOp.div;
            else return l;
            advance();
            l = new Binary(op, l, parseApp());
        }
    }

    private bool atomStart() const @safe nothrow @nogc
    {
        switch (cur.kind)
        {
            case Tok.integer, Tok.kwTrue, Tok.kwFalse, Tok.ident, Tok.lParen, Tok.lBracket:
                return true;
            default:
                return false;
        }
    }

    private Expr parseApp() @safe 
    {
        auto f = parseAtom();
        while (atomStart()) f = new App(f, parseAtom());
        return f;
    }

    private Expr parseAtom() @safe 
    {
        switch (cur.kind)
        {
            case Tok.integer:
            {
                auto e = new IntLit(src[cur.start .. cur.end]);
                advance();
                return e;
            }
            case Tok.kwTrue: advance(); return new BoolLit(true);
            case Tok.kwFalse: advance(); return new BoolLit(false);
            case Tok.ident:
            {
                auto e = new Var(src[cur.start .. cur.end]);
                advance();
                return e;
            }
            case Tok.lParen:
            {
                advance();
                if (accept(Tok.rParen)) return new UnitLit();
                auto first = parseExpr();
                if (cur.kind == Tok.comma)
                {
                    Expr[] elems = [first];
                    while (accept(Tok.comma)) elems ~= parseExpr();
                    expect(Tok.rParen, "')'");
                    return new Tuple(elems);
                }
                expect(Tok.rParen, "')'");
                return first;
            }
            case Tok.lBracket:
            {
                advance();
                if (accept(Tok.rBracket)) return new Nil();
                Expr[] elems = [parseExpr()];
                while (accept(Tok.semi)) elems ~= parseExpr();
                expect(Tok.rBracket, "']'");
                return new ListLit(elems);
            }
            default:
                throw fail("expression");
        }
    }
}

/// Parses a whole program. Throws `SyntaxError` on malformed input.
Decl[] parseProgram(string source) @safe 
{
    auto p = new Parser(source);
    Decl[] ds;
    while (!p.atEnd) ds ~= p.parseDecl();
    return ds;
}

private string itoa(size_t v) @safe nothrow
{
    char[20] buf;
    size_t i = buf.length;
    do { buf[--i] = cast(char)('0' + v % 10); v /= 10; } while (v);
    return buf[i .. $].idup;
}

@safe unittest
{
    auto ds = parseProgram("let f x y = x + 1;; (f);; let rec g n = g n;;");
    assert(ds.length == 3);
    assert(ds[0].isBinding && ds[0].name == "f" && !ds[0].isRec);
    auto lam = cast(Lam) ds[0].expr;
    assert(lam !is null && lam.params == ["x", "y"]);
    assert(!ds[1].isBinding);
    assert(ds[2].isRec);
}

@safe unittest
{
    // Precedence: f x + g y * 2 == (f x) + ((g y) * 2)
    auto ds = parseProgram("f x + g y * 2;;");
    auto b = cast(Binary) ds[0].expr;
    assert(b !is null && b.op == BinOp.add);
    assert(b.lhs.kind == ExprKind.app);
    auto m = cast(Binary) b.rhs;
    assert(m !is null && m.op == BinOp.mul);
}

@safe unittest
{
    // `::` is right-associative, `fun` bodies stop at `,`, tuples are flat.
    auto c = cast(Cons) parseProgram("1 :: 2 :: l;;")[0].expr;
    assert(c !is null && c.tail.kind == ExprKind.cons);
    auto t = cast(Tuple) parseProgram("(fun x -> x, 1, 2);;")[0].expr;
    assert(t !is null && t.elems.length == 3 && t.elems[0].kind == ExprKind.lam);
    auto l = cast(ListLit) parseProgram("[fun x -> x; fun y -> 1];;")[0].expr;
    assert(l !is null && l.elems.length == 2);
}

@safe unittest
{
    import std.exception : assertThrown;
    assertThrown!SyntaxError(parseProgram("let x = ;;"));
    assertThrown!SyntaxError(parseProgram("let rec f = fun x -> x;;"));
    assertThrown!SyntaxError(parseProgram("1 + ;;"));
    assert(parseProgram("  \n ").length == 0);
}
