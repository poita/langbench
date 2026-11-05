/**
 * Recursive-descent parser producing a flat `Program`.
 *
 * `let f x y = e` is desugared to nested `fun`s while parsing, and `::`
 * chains, `fun` parameter lists, tuples and list literals are collected
 * iteratively, so only genuine expression nesting consumes stack.
 */
module typeinfer.parser;

import typeinfer.ast;
import typeinfer.errors;
import typeinfer.lexer;

/**
 * Parse a token array (as produced by `tokenize`) into a program.
 *
 * Throws: `SyntaxError` if the tokens do not form a valid program.
 */
Program parse(const(Token)[] tokens)
{
    auto p = new Parser(tokens);
    return p.parseProgram();
}

private final class Parser
{
    const(Token)[] toks;
    size_t pos;
    Program prog;
    int[] scratch; // stack of pending sibling indices

    this(const(Token)[] toks) { this.toks = toks; }

    @property Tok kind() const { return toks[pos].kind; }

    SyntaxError error(string what)
    {
        return new SyntaxError(what, toks[pos].pos);
    }

    void expect(Tok k, string what)
    {
        if (kind != k)
            throw error("expected " ~ what);
        ++pos;
    }

    int add(Expr e)
    {
        prog.exprs ~= e;
        return cast(int) prog.exprs.length - 1;
    }

    Program parseProgram()
    {
        prog.exprs.reserve(toks.length);
        while (kind != Tok.eof)
            prog.decls ~= parseDecl();
        return prog;
    }

    Decl parseDecl()
    {
        if (kind == Tok.kwLet)
        {
            bool rec;
            int name, rhs;
            parseLetHead(rec, name, rhs);
            expect(Tok.semiSemi, "';;'");
            return Decl(rec ? DeclKind.letRec : DeclKind.let, name, rhs);
        }
        immutable e = parseExpr();
        expect(Tok.semiSemi, "';;'");
        return Decl(DeclKind.expr, -1, e);
    }

    /// Parses `let [rec] name params* = expr`; the cursor is on `let`.
    void parseLetHead(out bool rec, out int name, out int rhs)
    {
        ++pos;
        if (kind == Tok.kwRec)
        {
            rec = true;
            ++pos;
        }
        if (kind != Tok.ident)
            throw error("expected a name");
        name = toks[pos++].id;
        immutable base = scratch.length;
        while (kind == Tok.ident)
            scratch ~= toks[pos++].id;
        if (rec && scratch.length == base)
            throw error("'let rec' needs at least one parameter");
        expect(Tok.eq, "'='");
        rhs = wrapInFuns(base, parseExpr());
    }

    /// Wraps `body` in `fun` nodes for scratch[base .. $] and pops them.
    int wrapInFuns(size_t base, int body)
    {
        foreach_reverse (i; base .. scratch.length)
            body = add(Expr(ExprKind.fun, BinOp.add, scratch[i], body, 0));
        scratch.length = base;
        return body;
    }

    int parseExpr()
    {
        switch (kind)
        {
        case Tok.kwLet:
        {
            bool rec;
            int name, rhs;
            parseLetHead(rec, name, rhs);
            expect(Tok.kwIn, "'in'");
            immutable body = parseExpr();
            return add(Expr(rec ? ExprKind.letRec : ExprKind.let, BinOp.add, name, rhs, body));
        }
        case Tok.kwFun:
        {
            ++pos;
            immutable base = scratch.length;
            while (kind == Tok.ident)
                scratch ~= toks[pos++].id;
            if (scratch.length == base)
                throw error("expected a parameter");
            expect(Tok.arrow, "'->'");
            return wrapInFuns(base, parseExpr());
        }
        case Tok.kwIf:
        {
            ++pos;
            immutable c = parseExpr();
            expect(Tok.kwThen, "'then'");
            immutable a = parseExpr();
            expect(Tok.kwElse, "'else'");
            immutable b = parseExpr();
            return add(Expr(ExprKind.ifThenElse, BinOp.add, c, a, b));
        }
        default:
            return parseOr();
        }
    }

    int binary(BinOp op, int l, int r)
    {
        return add(Expr(ExprKind.binary, op, l, r, 0));
    }

    int parseOr()
    {
        auto l = parseAnd();
        while (kind == Tok.orOr)
        {
            ++pos;
            l = binary(BinOp.or, l, parseAnd());
        }
        return l;
    }

    int parseAnd()
    {
        auto l = parseCmp();
        while (kind == Tok.andAnd)
        {
            ++pos;
            l = binary(BinOp.and, l, parseCmp());
        }
        return l;
    }

    int parseCmp()
    {
        auto l = parseCons();
        BinOp op;
        switch (kind)
        {
        case Tok.eq:        op = BinOp.eq; break;
        case Tok.less:      op = BinOp.lt; break;
        case Tok.greater:   op = BinOp.gt; break;
        case Tok.lessEq:    op = BinOp.le; break;
        case Tok.greaterEq: op = BinOp.ge; break;
        default:            return l;
        }
        ++pos;
        return binary(op, l, parseCons());
    }

    int parseCons()
    {
        immutable first = parseAdd();
        if (kind != Tok.colonColon)
            return first;
        immutable base = scratch.length;
        scratch ~= first;
        while (kind == Tok.colonColon)
        {
            ++pos;
            scratch ~= parseAdd();
        }
        int acc = scratch[$ - 1];
        foreach_reverse (i; base .. scratch.length - 1)
            acc = add(Expr(ExprKind.cons, BinOp.add, scratch[i], acc, 0));
        scratch.length = base;
        return acc;
    }

    int parseAdd()
    {
        auto l = parseMul();
        while (kind == Tok.plus || kind == Tok.minus)
        {
            immutable op = kind == Tok.plus ? BinOp.add : BinOp.sub;
            ++pos;
            l = binary(op, l, parseMul());
        }
        return l;
    }

    int parseMul()
    {
        auto l = parseApp();
        while (kind == Tok.star || kind == Tok.slash)
        {
            immutable op = kind == Tok.star ? BinOp.mul : BinOp.div;
            ++pos;
            l = binary(op, l, parseApp());
        }
        return l;
    }

    bool atStartOfAtom() const
    {
        switch (kind)
        {
        case Tok.integer, Tok.ident, Tok.kwTrue, Tok.kwFalse, Tok.lparen, Tok.lbracket:
            return true;
        default:
            return false;
        }
    }

    int parseApp()
    {
        auto f = parseAtom();
        while (atStartOfAtom())
            f = add(Expr(ExprKind.app, BinOp.add, f, parseAtom(), 0));
        return f;
    }

    /// Moves scratch[base .. $] into the children pool; returns its start.
    int flush(size_t base)
    {
        immutable start = cast(int) prog.children.length;
        prog.children ~= scratch[base .. $];
        scratch.length = base;
        return start;
    }

    int parseAtom()
    {
        switch (kind)
        {
        case Tok.integer:
            ++pos;
            return add(Expr(ExprKind.intLit));
        case Tok.kwTrue:
            ++pos;
            return add(Expr(ExprKind.boolLit, BinOp.add, 1));
        case Tok.kwFalse:
            ++pos;
            return add(Expr(ExprKind.boolLit, BinOp.add, 0));
        case Tok.ident:
            return add(Expr(ExprKind.variable, BinOp.add, toks[pos++].id));
        case Tok.lparen:
        {
            ++pos;
            if (kind == Tok.rparen)
            {
                ++pos;
                return add(Expr(ExprKind.unitLit));
            }
            immutable first = parseExpr();
            if (kind == Tok.rparen)
            {
                ++pos;
                return first;
            }
            immutable base = scratch.length;
            scratch ~= first;
            while (kind == Tok.comma)
            {
                ++pos;
                scratch ~= parseExpr();
            }
            if (scratch.length - base < 2)
                throw error("expected ',' or ')'");
            expect(Tok.rparen, "')'");
            immutable count = cast(int)(scratch.length - base);
            immutable start = flush(base);
            return add(Expr(ExprKind.tuple, BinOp.add, start, count));
        }
        case Tok.lbracket:
        {
            ++pos;
            immutable base = scratch.length;
            if (kind != Tok.rbracket)
            {
                scratch ~= parseExpr();
                while (kind == Tok.semi)
                {
                    ++pos;
                    scratch ~= parseExpr();
                }
            }
            expect(Tok.rbracket, "']'");
            immutable count = cast(int)(scratch.length - base);
            immutable start = flush(base);
            return add(Expr(ExprKind.list, BinOp.add, start, count));
        }
        default:
            throw error("expected an expression");
        }
    }
}
