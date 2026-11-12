/**
 * Recursive-descent parser for the statements of the dialect.
 */
module minisql.parser;

import minisql.ast;
import minisql.errors;
import minisql.lexer;
import minisql.value;

/**
 * Parses the tokens of one statement (without its `;`).
 *
 * Throws: $(REF SqlError, minisql.errors) if the tokens are not a statement.
 */
Stmt parseStatement(const(Token)[] tokens) @safe
{
    auto p = Parser(tokens);
    auto s = p.statement();
    if (!p.atEnd)
        fail("syntax error: unexpected trailing input");
    return s;
}

private struct Parser
{
    const(Token)[] toks;
    size_t pos;

    this(const(Token)[] toks) @safe pure nothrow @nogc
    {
        this.toks = toks;
    }

    bool atEnd() const @safe pure nothrow @nogc
    {
        return pos >= toks.length;
    }

    // --- token helpers ---

    bool peekKeyword(Keyword k, size_t ahead = 0) const @safe pure nothrow @nogc
    {
        return pos + ahead < toks.length && toks[pos + ahead].kind == TokenKind.ident
            && toks[pos + ahead].keyword == k;
    }

    bool peekKind(TokenKind k, size_t ahead = 0) const @safe pure nothrow @nogc
    {
        return pos + ahead < toks.length && toks[pos + ahead].kind == k;
    }

    bool acceptKeyword(Keyword k) @safe pure nothrow @nogc
    {
        if (peekKeyword(k))
        {
            ++pos;
            return true;
        }
        return false;
    }

    bool acceptKind(TokenKind k) @safe pure nothrow @nogc
    {
        if (peekKind(k))
        {
            ++pos;
            return true;
        }
        return false;
    }

    void expectKeyword(Keyword k) @safe pure
    {
        if (!acceptKeyword(k))
            fail("syntax error: expected keyword");
    }

    void expectKind(TokenKind k) @safe pure
    {
        if (!acceptKind(k))
            fail("syntax error: unexpected token");
    }

    /// True if the next token is a plain (non-reserved) identifier.
    bool peekName() const @safe pure nothrow @nogc
    {
        return peekKind(TokenKind.ident) && toks[pos].keyword == Keyword.none;
    }

    string expectName() @safe pure
    {
        if (!peekName)
            fail("syntax error: expected a name");
        return toks[pos++].text;
    }

    long expectInteger() @safe pure
    {
        if (!peekKind(TokenKind.integer))
            fail("syntax error: expected an integer");
        return toks[pos++].value;
    }

    // --- statements ---

    Stmt statement() @safe pure
    {
        if (atEnd)
            fail("syntax error: empty statement");
        if (acceptKeyword(Keyword.create))
            return createTable();
        if (acceptKeyword(Keyword.insert))
            return insert();
        if (acceptKeyword(Keyword.delete_))
            return deleteFrom();
        if (acceptKeyword(Keyword.update))
            return update();
        if (acceptKeyword(Keyword.select))
            return select();
        fail("syntax error: unsupported statement");
    }

    Stmt createTable() @safe pure
    {
        auto s = new Stmt(StmtKind.createTable);
        expectKeyword(Keyword.table);
        s.table = expectName();
        expectKind(TokenKind.lparen);
        do
        {
            s.columnNames ~= expectName();
            if (!acceptKeyword(Keyword.integer) && !acceptKeyword(Keyword.text))
                fail("syntax error: expected INTEGER or TEXT");
        }
        while (acceptKind(TokenKind.comma));
        expectKind(TokenKind.rparen);
        return s;
    }

    Stmt insert() @safe pure
    {
        auto s = new Stmt(StmtKind.insert);
        expectKeyword(Keyword.into);
        s.table = expectName();
        expectKeyword(Keyword.values);
        do
        {
            expectKind(TokenKind.lparen);
            Expr[] row;
            do
                row ~= expr();
            while (acceptKind(TokenKind.comma));
            expectKind(TokenKind.rparen);
            s.rows ~= row;
        }
        while (acceptKind(TokenKind.comma));
        return s;
    }

    Stmt deleteFrom() @safe pure
    {
        auto s = new Stmt(StmtKind.delete_);
        expectKeyword(Keyword.from);
        s.table = expectName();
        if (acceptKeyword(Keyword.where))
            s.where = expr();
        return s;
    }

    Stmt update() @safe pure
    {
        auto s = new Stmt(StmtKind.update);
        s.table = expectName();
        expectKeyword(Keyword.set);
        do
        {
            s.setColumns ~= expectName();
            expectKind(TokenKind.eq);
            s.setValues ~= expr();
        }
        while (acceptKind(TokenKind.comma));
        if (acceptKeyword(Keyword.where))
            s.where = expr();
        return s;
    }

    TableRef tableRef() @safe pure
    {
        TableRef r;
        r.name = expectName();
        if (acceptKeyword(Keyword.as))
            r.alias_ = expectName();
        else if (peekName)
            r.alias_ = expectName();
        return r;
    }

    ColumnRef columnRef() @safe pure
    {
        ColumnRef c;
        c.name = expectName();
        if (acceptKind(TokenKind.dot))
        {
            c.qualifier = c.name;
            c.name = expectName();
        }
        return c;
    }

    Stmt select() @safe pure
    {
        auto s = new Stmt(StmtKind.select);
        do
        {
            SelectItem item;
            if (acceptKind(TokenKind.star))
                item.star = true;
            else
            {
                item.expr = expr();
                if (acceptKeyword(Keyword.as))
                    item.alias_ = expectName();
                else if (peekName)
                    item.alias_ = expectName();
            }
            s.items ~= item;
        }
        while (acceptKind(TokenKind.comma));

        if (acceptKeyword(Keyword.from))
        {
            s.from ~= tableRef();
            if (acceptKind(TokenKind.comma))
                s.from ~= tableRef();
            else if (peekKeyword(Keyword.inner) || peekKeyword(Keyword.join))
            {
                acceptKeyword(Keyword.inner);
                expectKeyword(Keyword.join);
                s.from ~= tableRef();
                expectKeyword(Keyword.on);
                s.joinOn = expr();
            }
        }
        if (acceptKeyword(Keyword.where))
            s.where = expr();
        if (acceptKeyword(Keyword.group))
        {
            expectKeyword(Keyword.by);
            do
                s.groupBy ~= columnRef();
            while (acceptKind(TokenKind.comma));
            if (acceptKeyword(Keyword.having))
                s.having = expr();
        }
        else if (peekKeyword(Keyword.having))
            fail("syntax error: HAVING requires GROUP BY");
        if (acceptKeyword(Keyword.order))
        {
            expectKeyword(Keyword.by);
            do
            {
                OrderTerm t;
                t.expr = expr();
                if (acceptKeyword(Keyword.desc))
                    t.descending = true;
                else
                    acceptKeyword(Keyword.asc);
                s.orderBy ~= t;
            }
            while (acceptKind(TokenKind.comma));
        }
        if (acceptKeyword(Keyword.limit))
        {
            s.hasLimit = true;
            s.limit = expectInteger();
            if (acceptKeyword(Keyword.offset))
                s.offset = expectInteger();
        }
        return s;
    }

    // --- expressions ---

    static Expr binary(BinOp op, Expr l, Expr r) @safe pure nothrow
    {
        auto e = new Expr(ExprKind.binary);
        e.op = op;
        e.lhs = l;
        e.rhs = r;
        return e;
    }

    Expr expr() @safe pure
    {
        auto l = andExpr();
        while (acceptKeyword(Keyword.or))
            l = binary(BinOp.or, l, andExpr());
        return l;
    }

    Expr andExpr() @safe pure
    {
        auto l = notExpr();
        while (acceptKeyword(Keyword.and))
            l = binary(BinOp.and, l, notExpr());
        return l;
    }

    Expr notExpr() @safe pure
    {
        if (acceptKeyword(Keyword.not))
        {
            auto e = new Expr(ExprKind.not);
            e.lhs = notExpr();
            return e;
        }
        return eqExpr();
    }

    Expr eqExpr() @safe pure
    {
        auto l = relExpr();
        for (;;)
        {
            BinOp op;
            if (acceptKind(TokenKind.eq))
                op = BinOp.eq;
            else if (acceptKind(TokenKind.ne))
                op = BinOp.ne;
            else if (peekKeyword(Keyword.is_))
            {
                ++pos;
                immutable negated = acceptKeyword(Keyword.not);
                expectKeyword(Keyword.null_);
                auto e = new Expr(negated ? ExprKind.isNotNull : ExprKind.isNull);
                e.lhs = l;
                l = e;
                continue;
            }
            else if (peekKeyword(Keyword.like) || (peekKeyword(Keyword.not) && peekKeyword(Keyword.like, 1)))
            {
                immutable negated = acceptKeyword(Keyword.not);
                expectKeyword(Keyword.like);
                auto e = new Expr(ExprKind.like);
                e.lhs = l;
                e.rhs = relExpr();
                if (negated)
                {
                    auto n = new Expr(ExprKind.not);
                    n.lhs = e;
                    l = n;
                }
                else
                    l = e;
                continue;
            }
            else
                return l;
            l = binary(op, l, relExpr());
        }
    }

    Expr relExpr() @safe pure
    {
        auto l = addExpr();
        for (;;)
        {
            BinOp op;
            if (acceptKind(TokenKind.lt))
                op = BinOp.lt;
            else if (acceptKind(TokenKind.le))
                op = BinOp.le;
            else if (acceptKind(TokenKind.gt))
                op = BinOp.gt;
            else if (acceptKind(TokenKind.ge))
                op = BinOp.ge;
            else
                return l;
            l = binary(op, l, addExpr());
        }
    }

    Expr addExpr() @safe pure
    {
        auto l = mulExpr();
        for (;;)
        {
            BinOp op;
            if (acceptKind(TokenKind.plus))
                op = BinOp.add;
            else if (acceptKind(TokenKind.minus))
                op = BinOp.sub;
            else
                return l;
            l = binary(op, l, mulExpr());
        }
    }

    Expr mulExpr() @safe pure
    {
        auto l = unary();
        for (;;)
        {
            BinOp op;
            if (acceptKind(TokenKind.star))
                op = BinOp.mul;
            else if (acceptKind(TokenKind.slash))
                op = BinOp.div;
            else if (acceptKind(TokenKind.percent))
                op = BinOp.mod;
            else
                return l;
            l = binary(op, l, unary());
        }
    }

    Expr unary() @safe pure
    {
        if (acceptKind(TokenKind.minus))
        {
            auto e = new Expr(ExprKind.negate);
            e.lhs = unary();
            return e;
        }
        return primary();
    }

    static Expr literal(Value v) @safe pure nothrow
    {
        auto e = new Expr(ExprKind.literal);
        e.value = v;
        return e;
    }

    Expr primary() @safe pure
    {
        if (atEnd)
            fail("syntax error: unexpected end of statement");
        immutable t = toks[pos];
        switch (t.kind)
        {
        case TokenKind.integer:
            ++pos;
            return literal(Value.integer(t.value));
        case TokenKind.string_:
            ++pos;
            return literal(Value.text(t.text));
        case TokenKind.lparen:
            ++pos;
            auto e = expr();
            expectKind(TokenKind.rparen);
            return e;
        case TokenKind.ident:
            if (t.keyword == Keyword.null_)
            {
                ++pos;
                return literal(Value.null_);
            }
            if (t.keyword != Keyword.none)
                fail("syntax error: unexpected keyword");
            if (peekKind(TokenKind.lparen, 1))
                return aggregate();
            auto e = new Expr(ExprKind.column);
            auto c = columnRef();
            e.qualifier = c.qualifier;
            e.name = c.name;
            return e;
        default:
            fail("syntax error: unexpected token");
        }
    }

    Expr aggregate() @safe pure
    {
        auto e = new Expr(ExprKind.aggregate);
        switch (toks[pos].text)
        {
        case "count": e.func = AggFunc.count; break;
        case "sum": e.func = AggFunc.sum; break;
        case "min": e.func = AggFunc.min; break;
        case "max": e.func = AggFunc.max; break;
        case "avg": e.func = AggFunc.avg; break;
        default:
            fail("syntax error: unknown function");
        }
        pos += 2; // name and '('
        if (e.func == AggFunc.count && acceptKind(TokenKind.star))
            e.star = true;
        else
            e.lhs = expr();
        expectKind(TokenKind.rparen);
        return e;
    }
}

version (unittest)
{
    private bool parses(string sql) @safe
    {
        auto stmts = splitStatements(sql);
        if (stmts.length != 1)
            return false;
        try
        {
            parseStatement(stmts[0]);
            return true;
        }
        catch (SqlError)
            return false;
    }
}

@("accepts every statement form of the dialect")
unittest
{
    assert(parses("CREATE TABLE t (a INTEGER, b TEXT)"));
    assert(parses("INSERT INTO t VALUES (1, 'x'), (2, NULL)"));
    assert(parses("DELETE FROM t WHERE a = 1"));
    assert(parses("UPDATE t SET a = 1, b = 'y' WHERE a IS NOT NULL"));
    assert(parses("SELECT * FROM t"));
    assert(parses("SELECT 1 + 1"));
    assert(parses("SELECT a x, b AS y, COUNT(*) FROM t u, v WHERE a NOT LIKE 'x%' GROUP BY a, u.b HAVING count (a) > 1 ORDER BY 1 DESC, x LIMIT 3 OFFSET 2"));
    assert(parses("SELECT * FROM t INNER JOIN u ON t.a = u.a"));
    assert(parses("SELECT * FROM t JOIN u v ON t.a = v.a"));
    assert(parses("SELECT count FROM t"));
}

@("rejects unsupported or malformed SQL")
unittest
{
    assert(!parses("DROP TABLE t"));
    assert(!parses("CREATE TABLE t ()"));
    assert(!parses("CREATE TABLE t (a REAL)"));
    assert(!parses("CREATE TABLE t (a)"));
    assert(!parses("CREATE TABLE t (text TEXT)"));
    assert(!parses("INSERT INTO t (a) VALUES (1)"));
    assert(!parses("SELECT a AS left FROM t"));
    assert(!parses("SELECT * FROM t LEFT JOIN u ON 1"));
    assert(!parses("SELECT * FROM a, b, c"));
    assert(!parses("SELECT a FROM t WHERE a IN (1)"));
    assert(!parses("SELECT a FROM t WHERE a BETWEEN 1 AND 2"));
    assert(!parses("SELECT 'a' || 'b'"));
    assert(!parses("SELECT 1.5"));
    assert(!parses("SELECT a FROM t HAVING a > 1"));
    assert(!parses("SELECT a FROM t GROUP BY a + 1"));
    assert(!parses("SELECT a FROM t LIMIT -1"));
    assert(!parses("SELECT a FROM t OFFSET 1"));
    assert(!parses("SELECT foo(a) FROM t"));
    assert(!parses("SELECT SUM(*) FROM t"));
    assert(!parses("SELECT * AS x FROM t"));
    assert(!parses("SELECT 'unterminated"));
}

@("operator precedence follows the grammar")
unittest
{
    auto stmts = splitStatements("SELECT NOT a = 1, a + 1 IS NULL, 1 < 2 = 1, -5 % 3, 1 + 2 * 3");
    auto s = parseStatement(stmts[0]);
    assert(s.items[0].expr.kind == ExprKind.not);
    assert(s.items[0].expr.lhs.op == BinOp.eq);
    assert(s.items[1].expr.kind == ExprKind.isNull);
    assert(s.items[1].expr.lhs.op == BinOp.add);
    assert(s.items[2].expr.op == BinOp.eq && s.items[2].expr.lhs.op == BinOp.lt);
    assert(s.items[3].expr.op == BinOp.mod && s.items[3].expr.lhs.kind == ExprKind.negate);
    assert(s.items[4].expr.op == BinOp.add && s.items[4].expr.rhs.op == BinOp.mul);
}
