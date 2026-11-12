/// Recursive-descent parser: filter text to a `Node` tree.
module jq.parser;

import jq.ast;
import jq.error;
import jq.lexer;
import jq.value;

/// Compiles filter text. Throws `JqSyntaxError` if it is not valid.
Node parseFilter(string src)
{
    auto p = Parser(tokenize(src));
    auto n = p.parsePipe();
    if (p.peek.kind != Tok.eof)
        throw new JqSyntaxError("unexpected token at offset " ~ itoa(p.peek.pos));
    return n;
}

private string itoa(size_t n)
{
    import std.conv : to;

    return n.to!string;
}

private struct Parser
{
    Token[] toks;
    size_t p;
    int[string] vars;

    this(Token[] t)
    {
        toks = t;
    }

    ref const(Token) peek() const
    {
        return toks[p];
    }

    Token next()
    {
        auto t = toks[p];
        if (t.kind != Tok.eof)
            ++p;
        return t;
    }

    bool accept(Tok k)
    {
        if (toks[p].kind == k)
        {
            ++p;
            return true;
        }
        return false;
    }

    void expect(Tok k, string what)
    {
        if (!accept(k))
            throw new JqSyntaxError("expected " ~ what ~ " at offset " ~ itoa(toks[p].pos));
    }

    bool isKeyword(string kw) const
    {
        return toks[p].kind == Tok.ident && toks[p].text == kw;
    }

    void expectKeyword(string kw)
    {
        if (!isKeyword(kw))
            throw new JqSyntaxError("expected '" ~ kw ~ "' at offset " ~ itoa(toks[p].pos));
        ++p;
    }

    int varId(string name)
    {
        if (auto q = name in vars)
            return *q;
        immutable id = cast(int) vars.length;
        vars[name] = id;
        return id;
    }

    // ---- node constructors (they also compute `single`) ----

    static Node mk(Op op, Node a = null, Node b = null, Node c = null)
    {
        auto n = new Node(op);
        n.a = a;
        n.b = b;
        n.c = c;
        return n;
    }

    static Node mkLit(Value v)
    {
        auto n = mk(Op.literal);
        n.lit = v;
        n.single = true;
        return n;
    }

    static Node mkIdentity()
    {
        auto n = mk(Op.identity);
        n.single = true;
        return n;
    }

    static Node mkField(Node target, string name)
    {
        auto n = mk(Op.field, target);
        n.name = name;
        n.single = target.single;
        return n;
    }

    static Node mkBin(BinOp op, Node a, Node b)
    {
        auto n = mk(Op.binop, a, b);
        n.bop = op;
        n.single = a.single && b.single;
        return n;
    }

    // ---- grammar ----

    Node parsePipe()
    {
        auto l = parseComma();
        if (accept(Tok.pipe))
        {
            auto r = parsePipe();
            auto n = mk(Op.pipe, l, r);
            n.single = l.single && r.single;
            return n;
        }
        return l;
    }

    Node parseComma()
    {
        auto l = parseOr();
        while (accept(Tok.comma))
            l = mk(Op.comma, l, parseOr());
        return l;
    }

    Node parseOr()
    {
        auto l = parseAnd();
        while (isKeyword("or"))
        {
            ++p;
            auto r = parseAnd();
            l = mk(Op.or, l, r);
            l.single = l.a.single && r.single;
        }
        return l;
    }

    Node parseAnd()
    {
        auto l = parseCmp();
        while (isKeyword("and"))
        {
            ++p;
            auto r = parseCmp();
            l = mk(Op.and, l, r);
            l.single = l.a.single && r.single;
        }
        return l;
    }

    Node parseCmp()
    {
        auto l = parseAdd();
        BinOp op;
        switch (peek.kind)
        {
        case Tok.eq:
            op = BinOp.eq;
            break;
        case Tok.ne:
            op = BinOp.ne;
            break;
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
        ++p;
        return mkBin(op, l, parseAdd());
    }

    Node parseAdd()
    {
        auto l = parseMul();
        while (true)
        {
            if (accept(Tok.plus))
                l = mkBin(BinOp.add, l, parseMul());
            else if (accept(Tok.minus))
                l = mkBin(BinOp.sub, l, parseMul());
            else
                return l;
        }
    }

    Node parseMul()
    {
        auto l = parseUnary();
        while (true)
        {
            if (accept(Tok.star))
                l = mkBin(BinOp.mul, l, parseUnary());
            else if (accept(Tok.slash))
                l = mkBin(BinOp.div, l, parseUnary());
            else if (accept(Tok.percent))
                l = mkBin(BinOp.mod, l, parseUnary());
            else
                return l;
        }
    }

    Node parseUnary()
    {
        if (accept(Tok.minus))
        {
            auto x = parseUnary();
            auto n = mk(Op.neg, x);
            n.single = x.single;
            return n;
        }
        return parsePostfix(true);
    }

    /// postfix := primary { suffix }; with `allowAs`, also `postfix as $x | pipe`.
    Node parsePostfix(bool allowAs)
    {
        bool lastIsPathOp; // does `t` end in a field/index/slice/iterate op?
        auto t = parsePrimary(lastIsPathOp);
        while (true)
        {
            immutable k = peek.kind;
            if (k == Tok.field)
            {
                auto tk = next();
                t = mkField(t, tk.text);
                lastIsPathOp = true;
            }
            else if (k == Tok.dot && toks[p + 1].adjacent && toks[p + 1].kind == Tok.string_)
            {
                ++p;
                t = mkField(t, next().text);
                lastIsPathOp = true;
            }
            else if (k == Tok.dot && toks[p + 1].adjacent && toks[p + 1].kind == Tok.lbrack)
            {
                ++p; // `.a.[0]`
            }
            else if (k == Tok.lbrack)
            {
                ++p;
                t = parseBracket(t);
                lastIsPathOp = true;
            }
            else if (k == Tok.question)
            {
                ++p;
                if (lastIsPathOp)
                {
                    t.opt = true;
                    t.single = false;
                    lastIsPathOp = false;
                }
                else
                {
                    t = mk(Op.try_, t);
                }
            }
            else
                break;
        }
        if (allowAs && isKeyword("as"))
        {
            ++p;
            auto v = next();
            if (v.kind != Tok.var)
                throw new JqSyntaxError("expected a variable after 'as'");
            expect(Tok.pipe, "'|'");
            auto body_ = parsePipe();
            auto n = mk(Op.bind, t, body_);
            n.varId = varId(v.text);
            n.single = t.single && body_.single;
            return n;
        }
        return t;
    }

    /// Parses after `[`: index, iterate or slice.
    Node parseBracket(Node target)
    {
        if (accept(Tok.rbrack))
        {
            auto n = mk(Op.iterate, target);
            return n;
        }
        Node from, to;
        if (peek.kind == Tok.colon)
        {
            ++p;
            if (peek.kind != Tok.rbrack)
                to = parsePipe();
            expect(Tok.rbrack, "']'");
            return mk(Op.slice, target, from, to);
        }
        from = parsePipe();
        if (accept(Tok.colon))
        {
            if (peek.kind != Tok.rbrack)
                to = parsePipe();
            expect(Tok.rbrack, "']'");
            return mk(Op.slice, target, from, to);
        }
        expect(Tok.rbrack, "']'");
        auto n = mk(Op.index, target, from);
        n.single = target.single && from.single;
        return n;
    }

    /// `isPath` reports whether the primary is itself a field access (`.a`, `."a"`),
    /// which a following `?` makes tolerant rather than wrapping in try.
    Node parsePrimary(out bool isPath)
    {
        auto t = next();
        if (t.kind == Tok.field)
        {
            isPath = true;
            return mkField(mkIdentity(), t.text);
        }
        if (t.kind == Tok.dot && peek.kind == Tok.string_ && peek.adjacent)
        {
            isPath = true;
            return mkField(mkIdentity(), next().text);
        }
        isPath = false;
        switch (t.kind)
        {
        case Tok.dot:
            return mkIdentity();
        case Tok.number:
            return mkLit(Value.makeNumber(t.num));
        case Tok.string_:
            return mkLit(Value.makeString(t.text));
        case Tok.var:
            {
                auto n = mk(Op.var);
                n.varId = varId(t.text);
                n.name = t.text;
                n.single = true;
                return n;
            }
        case Tok.lparen:
            {
                auto e = parsePipe();
                expect(Tok.rparen, "')'");
                return e;
            }
        case Tok.lbrack:
            {
                Node body_;
                if (peek.kind != Tok.rbrack)
                    body_ = parsePipe();
                expect(Tok.rbrack, "']'");
                auto n = mk(Op.array, body_);
                n.single = true;
                return n;
            }
        case Tok.lbrace:
            return parseObject();
        case Tok.ident:
            return parseIdent(t);
        default:
            throw new JqSyntaxError("unexpected token at offset " ~ itoa(t.pos));
        }
    }

    Node parseObject()
    {
        auto n = mk(Op.object);
        bool single = true;
        if (!accept(Tok.rbrace))
        {
            while (true)
            {
                ObjEntry e;
                auto t = next();
                if (t.kind == Tok.ident || t.kind == Tok.string_)
                {
                    e.litKey = t.text;
                    if (accept(Tok.colon))
                        e.val = parseObjVal();
                    else
                        e.val = mkField(mkIdentity(), t.text);
                }
                else if (t.kind == Tok.var)
                {
                    e.litKey = t.text;
                    auto v = mk(Op.var);
                    v.varId = varId(t.text);
                    v.name = t.text;
                    v.single = true;
                    e.val = v;
                }
                else if (t.kind == Tok.lparen)
                {
                    e.keyExpr = parsePipe();
                    expect(Tok.rparen, "')'");
                    expect(Tok.colon, "':'");
                    e.val = parseObjVal();
                    single = single && e.keyExpr.single;
                }
                else
                    throw new JqSyntaxError("bad object key at offset " ~ itoa(t.pos));
                single = single && e.val.single;
                n.entries ~= e;
                if (accept(Tok.comma))
                    continue;
                expect(Tok.rbrace, "'}'");
                break;
            }
        }
        n.single = single;
        return n;
    }

    Node parseObjTerm()
    {
        if (accept(Tok.minus))
        {
            auto x = parseObjTerm();
            auto n = mk(Op.neg, x);
            n.single = x.single;
            return n;
        }
        return parsePostfix(false);
    }

    Node parseObjVal()
    {
        auto l = parseObjTerm();
        if (accept(Tok.pipe))
        {
            auto r = parseObjVal();
            auto n = mk(Op.pipe, l, r);
            n.single = l.single && r.single;
            return n;
        }
        return l;
    }

    Node parseIdent(Token t)
    {
        switch (t.text)
        {
        case "true":
            return mkLit(Value.makeBool(true));
        case "false":
            return mkLit(Value.makeBool(false));
        case "null":
            return mkLit(Value.makeNull());
        case "if":
            return parseIf();
        case "reduce":
            {
                auto src = parsePostfix(false);
                expectKeyword("as");
                auto v = next();
                if (v.kind != Tok.var)
                    throw new JqSyntaxError("expected a variable after 'as'");
                expect(Tok.lparen, "'('");
                auto init = parsePipe();
                expect(Tok.semi, "';'");
                auto upd = parsePipe();
                expect(Tok.rparen, "')'");
                auto n = mk(Op.reduce, src, init, upd);
                n.varId = varId(v.text);
                n.single = init.single;
                return n;
            }
        default:
            break;
        }
        Node[] args;
        if (accept(Tok.lparen))
        {
            args ~= parsePipe();
            while (accept(Tok.semi))
                args ~= parsePipe();
            expect(Tok.rparen, "')'");
        }
        return mkCall(t.text, args);
    }

    Node parseIf()
    {
        auto cond = parsePipe();
        expectKeyword("then");
        auto then_ = parsePipe();
        Node else_;
        if (isKeyword("elif"))
        {
            ++p;
            else_ = parseIf(); // consumes through the shared `end`
            auto n = mk(Op.if_, cond, then_, else_);
            n.single = cond.single && then_.single && else_.single;
            return n;
        }
        if (isKeyword("else"))
        {
            ++p;
            else_ = parsePipe();
        }
        expectKeyword("end");
        auto n = mk(Op.if_, cond, then_, else_);
        n.single = cond.single && then_.single && (else_ is null || else_.single);
        return n;
    }

    Node mkCall(string name, Node[] args)
    {
        auto n = mk(Op.call);
        n.name = name;
        n.args = args;
        void arity(size_t k)
        {
            if (args.length != k)
                throw new JqSyntaxError(name ~ " takes " ~ itoa(k) ~ " argument(s)");
        }

        switch (name)
        {
        case "empty":
            arity(0);
            n.bi = Builtin.empty;
            return n;
        case "error":
            if (args.length == 0)
            {
                n.bi = Builtin.error0;
                n.single = true; // raises
            }
            else
            {
                arity(1);
                n.bi = Builtin.error1;
            }
            return n;
        case "select":
            arity(1);
            n.bi = Builtin.select;
            return n;
        case "map":
            arity(1);
            n.bi = Builtin.map;
            n.single = true;
            return n;
        case "sort_by":
            arity(1);
            n.bi = Builtin.sort_by;
            n.single = true;
            return n;
        case "group_by":
            arity(1);
            n.bi = Builtin.group_by;
            n.single = true;
            return n;
        case "has":
            arity(1);
            n.bi = Builtin.has;
            n.single = args[0].single;
            return n;
        default:
            break;
        }
        arity(0);
        n.single = true;
        switch (name)
        {
        case "not":
            n.bi = Builtin.not;
            break;
        case "length":
            n.bi = Builtin.length;
            break;
        case "keys":
            n.bi = Builtin.keys;
            break;
        case "type":
            n.bi = Builtin.type;
            break;
        case "add":
            n.bi = Builtin.add;
            break;
        case "sort":
            n.bi = Builtin.sort;
            break;
        case "unique":
            n.bi = Builtin.unique;
            break;
        case "reverse":
            n.bi = Builtin.reverse;
            break;
        case "min":
            n.bi = Builtin.min;
            break;
        case "max":
            n.bi = Builtin.max;
            break;
        case "tostring":
            n.bi = Builtin.tostring;
            break;
        case "tonumber":
            n.bi = Builtin.tonumber;
            break;
        default:
            throw new JqSyntaxError("unknown function: " ~ name);
        }
        return n;
    }
}

unittest
{
    import std.exception : assertThrown;

    // `.a?` makes one operation tolerant; `(.a)?` and `f?` are try
    auto n = parseFilter(".a.b?");
    assert(n.op == Op.field && n.opt && !n.a.opt);
    n = parseFilter("(.a)?");
    assert(n.op == Op.try_);
    n = parseFilter(".a??");
    assert(n.op == Op.try_ && n.a.opt);
    // `|` is right-associative and looser than `,`
    n = parseFilter("1, 2 | 3");
    assert(n.op == Op.pipe && n.a.op == Op.comma);
    // `as` binds the rest of the pipe
    n = parseFilter(". as $x | $x, 1");
    assert(n.op == Op.bind && n.b.op == Op.comma);
    assertThrown!JqSyntaxError(parseFilter("1 +"));
    assertThrown!JqSyntaxError(parseFilter("[1"));
}
