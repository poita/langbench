/// Recursive-descent parser: one function per precedence level of the grammar.
module minisql.parser;

import minisql.ast;
import minisql.errors;
import minisql.lexer;

/// Parses the tokens of exactly one statement (without its `;`).
/// Throws `SqlException` on any syntax error.
Statement parseStatement(const(Token)[] toks) @safe
{
    auto p = Parser(toks);
    return p.statement();
}

private struct Parser
{
    const(Token)[] toks;
    size_t pos;

    this(const(Token)[] t) @safe
    {
        toks = t;
    }

    Tok peek(size_t ahead = 0) const pure nothrow @nogc @safe
    {
        return pos + ahead < toks.length ? toks[pos + ahead].kind : Tok.eof;
    }

    bool accept(Tok k) pure @safe
    {
        if (peek() == k)
        {
            pos++;
            return true;
        }
        return false;
    }

    void expect(Tok k) pure @safe
    {
        if (!accept(k))
            fail("syntax error");
    }

    string expectName() pure @safe
    {
        if (peek() != Tok.ident)
            fail("syntax error: expected a name");
        return toks[pos++].text;
    }

    long expectInteger() pure @safe
    {
        if (peek() != Tok.integer)
            fail("syntax error: expected an integer");
        return toks[pos++].value;
    }

    void expectEnd() pure @safe
    {
        if (pos != toks.length)
            fail("syntax error: unexpected token");
    }

    // ---- statements ----

    Statement statement() @safe
    {
        Statement s;
        switch (peek())
        {
        case Tok.kSelect:
            s = select();
            break;
        case Tok.kInsert:
            s = insert();
            break;
        case Tok.kDelete:
            s = delete_();
            break;
        case Tok.kUpdate:
            s = update();
            break;
        case Tok.kCreate:
            s = create();
            break;
        default:
            fail("syntax error: unsupported statement");
        }
        expectEnd();
        return s;
    }

    Statement create() @safe
    {
        pos++;
        expect(Tok.kTable);
        auto st = new CreateStmt;
        st.table = expectName();
        expect(Tok.lparen);
        do
        {
            st.columns ~= expectName();
            if (!accept(Tok.kInteger) && !accept(Tok.kText))
                fail("syntax error: expected a column type");
        }
        while (accept(Tok.comma));
        expect(Tok.rparen);
        return st;
    }

    Statement insert() @safe
    {
        pos++;
        expect(Tok.kInto);
        auto st = new InsertStmt;
        st.table = expectName();
        expect(Tok.kValues);
        do
        {
            expect(Tok.lparen);
            Expr[] row;
            do
                row ~= expr();
            while (accept(Tok.comma));
            expect(Tok.rparen);
            st.rows ~= row;
        }
        while (accept(Tok.comma));
        return st;
    }

    Statement delete_() @safe
    {
        pos++;
        expect(Tok.kFrom);
        auto st = new DeleteStmt;
        st.table = expectName();
        if (accept(Tok.kWhere))
            st.where_ = expr();
        return st;
    }

    Statement update() @safe
    {
        pos++;
        auto st = new UpdateStmt;
        st.table = expectName();
        expect(Tok.kSet);
        do
        {
            st.columns ~= expectName();
            expect(Tok.eq);
            st.values ~= expr();
        }
        while (accept(Tok.comma));
        if (accept(Tok.kWhere))
            st.where_ = expr();
        return st;
    }

    TableRef tableRef() pure @safe
    {
        TableRef r;
        r.name = expectName();
        if (accept(Tok.kAs))
            r.alias_ = expectName();
        else if (peek() == Tok.ident)
            r.alias_ = expectName();
        return r;
    }

    ColumnRef columnRef() pure @safe
    {
        ColumnRef c;
        c.name = expectName();
        if (accept(Tok.dot))
        {
            c.qualifier = c.name;
            c.name = expectName();
        }
        return c;
    }

    SelectStmt select() @safe
    {
        pos++;
        auto st = new SelectStmt;
        do
        {
            SelectItem it;
            if (accept(Tok.star))
                it.star = true;
            else
            {
                it.expr = expr();
                if (accept(Tok.kAs))
                    it.alias_ = expectName();
                else if (peek() == Tok.ident)
                    it.alias_ = expectName();
            }
            st.items ~= it;
        }
        while (accept(Tok.comma));

        if (accept(Tok.kFrom))
        {
            st.from ~= tableRef();
            if (accept(Tok.comma))
                st.from ~= tableRef();
            else if (peek() == Tok.kJoin || peek() == Tok.kInner)
            {
                if (accept(Tok.kInner))
                    expect(Tok.kJoin);
                else
                    pos++;
                st.from ~= tableRef();
                expect(Tok.kOn);
                st.on = expr();
            }
        }
        if (accept(Tok.kWhere))
            st.where_ = expr();
        if (accept(Tok.kGroup))
        {
            expect(Tok.kBy);
            do
                st.groupBy ~= columnRef();
            while (accept(Tok.comma));
        }
        if (accept(Tok.kHaving))
        {
            if (st.groupBy.length == 0)
                fail("HAVING requires GROUP BY");
            st.having = expr();
        }
        if (accept(Tok.kOrder))
        {
            expect(Tok.kBy);
            do
            {
                OrderTerm t;
                t.expr = expr();
                if (accept(Tok.kDesc))
                    t.desc = true;
                else
                    accept(Tok.kAsc);
                st.orderBy ~= t;
            }
            while (accept(Tok.comma));
        }
        if (accept(Tok.kLimit))
        {
            st.hasLimit = true;
            st.limit = expectInteger();
            if (accept(Tok.kOffset))
                st.offset = expectInteger();
        }
        return st;
    }

    // ---- expressions ----

    static Expr bin(BinOp op, Expr l, Expr r) pure @safe
    {
        auto e = new Expr;
        e.kind = ExprKind.binary;
        e.op = op;
        e.lhs = l;
        e.rhs = r;
        return e;
    }

    static Expr unary(ExprKind k, Expr operand) pure @safe
    {
        auto e = new Expr;
        e.kind = k;
        e.lhs = operand;
        return e;
    }

    Expr expr() pure @safe
    {
        auto l = andExpr();
        while (accept(Tok.kOr))
            l = bin(BinOp.or, l, andExpr());
        return l;
    }

    Expr andExpr() pure @safe
    {
        auto l = notExpr();
        while (accept(Tok.kAnd))
            l = bin(BinOp.and, l, notExpr());
        return l;
    }

    Expr notExpr() pure @safe
    {
        if (accept(Tok.kNot))
            return unary(ExprKind.not, notExpr());
        return eqExpr();
    }

    Expr eqExpr() pure @safe
    {
        auto l = relExpr();
        for (;;)
        {
            switch (peek())
            {
            case Tok.eq:
                pos++;
                l = bin(BinOp.eq, l, relExpr());
                break;
            case Tok.ne:
                pos++;
                l = bin(BinOp.ne, l, relExpr());
                break;
            case Tok.kIs:
                pos++;
                if (accept(Tok.kNot))
                {
                    expect(Tok.kNull);
                    l = unary(ExprKind.isNotNull, l);
                }
                else
                {
                    expect(Tok.kNull);
                    l = unary(ExprKind.isNull, l);
                }
                break;
            case Tok.kLike:
                pos++;
                l = bin(BinOp.like, l, relExpr());
                break;
            case Tok.kNot:
                pos++;
                expect(Tok.kLike);
                l = unary(ExprKind.not, bin(BinOp.like, l, relExpr()));
                break;
            default:
                return l;
            }
        }
    }

    Expr relExpr() pure @safe
    {
        auto l = addExpr();
        for (;;)
        {
            BinOp op;
            switch (peek())
            {
            case Tok.lt:
                op = BinOp.lt;
                break;
            case Tok.le:
                op = BinOp.le;
                break;
            case Tok.gt:
                op = BinOp.gt;
                break;
            case Tok.ge:
                op = BinOp.ge;
                break;
            default:
                return l;
            }
            pos++;
            l = bin(op, l, addExpr());
        }
    }

    Expr addExpr() pure @safe
    {
        auto l = mulExpr();
        for (;;)
        {
            if (accept(Tok.plus))
                l = bin(BinOp.add, l, mulExpr());
            else if (accept(Tok.minus))
                l = bin(BinOp.sub, l, mulExpr());
            else
                return l;
        }
    }

    Expr mulExpr() pure @safe
    {
        auto l = unaryExpr();
        for (;;)
        {
            if (accept(Tok.star))
                l = bin(BinOp.mul, l, unaryExpr());
            else if (accept(Tok.slash))
                l = bin(BinOp.div, l, unaryExpr());
            else if (accept(Tok.percent))
                l = bin(BinOp.mod, l, unaryExpr());
            else
                return l;
        }
    }

    Expr unaryExpr() pure @safe
    {
        if (accept(Tok.minus))
            return unary(ExprKind.neg, unaryExpr());
        return primary();
    }

    Expr primary() pure @safe
    {
        auto e = new Expr;
        switch (peek())
        {
        case Tok.integer:
            e.kind = ExprKind.intLit;
            e.intValue = toks[pos++].value;
            return e;
        case Tok.string_:
            e.kind = ExprKind.strLit;
            e.text = toks[pos++].text;
            return e;
        case Tok.kNull:
            pos++;
            e.kind = ExprKind.nullLit;
            return e;
        case Tok.lparen:
            pos++;
            auto inner = expr();
            expect(Tok.rparen);
            return inner;
        case Tok.ident:
            immutable name = toks[pos++].text;
            if (peek() == Tok.lparen)
                return aggregate(name);
            e.kind = ExprKind.column;
            if (accept(Tok.dot))
            {
                e.qualifier = name;
                e.text = expectName();
            }
            else
                e.text = name;
            return e;
        default:
            fail("syntax error: expected an expression");
        }
    }

    Expr aggregate(string name) pure @safe
    {
        auto e = new Expr;
        e.kind = ExprKind.aggregate;
        switch (name)
        {
        case "count":
            e.fn = AggFn.count;
            break;
        case "sum":
            e.fn = AggFn.sum;
            break;
        case "min":
            e.fn = AggFn.min;
            break;
        case "max":
            e.fn = AggFn.max;
            break;
        case "avg":
            e.fn = AggFn.avg;
            break;
        default:
            fail("syntax error: unknown function");
        }
        expect(Tok.lparen);
        if (e.fn == AggFn.count && accept(Tok.star))
            e.star = true;
        else
            e.lhs = expr();
        expect(Tok.rparen);
        return e;
    }
}
