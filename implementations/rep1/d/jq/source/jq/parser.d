/**
 * Recursive-descent parser turning filter source text into an AST.
 */
module jq.parser;

import jq.ast;
import jq.lexer;
import jq.ops : BinOp;
import jq.value;

/// Parse the filter `src`. Throws `FilterException` if it is malformed.
Node parseFilter(string src)
{
    auto p = new FilterParser(src);
    return p.parseProgram();
}

private final class FilterParser
{
    Token[] toks;
    size_t pos;
    int[string] varIds;

    this(string src)
    {
        toks = tokenize(src);
    }

    FilterException fail(string msg)
    {
        return new FilterException(msg, toks[pos].start);
    }

    ref const(Token) peek() const { return toks[pos]; }
    Tok kind() const { return toks[pos].kind; }

    bool isIdent(string name) const
    {
        return toks[pos].kind == Tok.ident && toks[pos].text == name;
    }

    bool accept(Tok k)
    {
        if (toks[pos].kind == k)
        {
            ++pos;
            return true;
        }
        return false;
    }

    void expect(Tok k, string what)
    {
        if (!accept(k))
            throw fail("expected " ~ what);
    }

    void expectKeyword(string kw)
    {
        if (!isIdent(kw))
            throw fail("expected '" ~ kw ~ "'");
        ++pos;
    }

    Node parseProgram()
    {
        if (kind == Tok.eof)
            return finish(new Node(Kind.identity));
        auto n = parsePipe();
        if (kind != Tok.eof)
            throw fail("unexpected token");
        return n;
    }

    // -- node construction ---------------------------------------------------

    Node finish(Node n)
    {
        final switch (n.kind)
        {
        case Kind.identity, Kind.literal, Kind.variable:
        case Kind.arrayCons, Kind.not, Kind.length, Kind.keys, Kind.type, Kind.add,
            Kind.sort, Kind.unique, Kind.reverse, Kind.min, Kind.max,
            Kind.toStringOp, Kind.toNumberOp, Kind.map, Kind.sortBy, Kind.groupBy:
            n.single = true;
            break;
        case Kind.field:
            n.single = !n.opt && n.a.single;
            break;
        case Kind.index:
            n.single = !n.opt && n.a.single && n.b.single;
            break;
        case Kind.slice:
            n.single = !n.opt && n.a.single && (n.b is null || n.b.single) && (n.c is null || n.c.single);
            break;
        case Kind.iterate, Kind.tryOp, Kind.comma, Kind.empty, Kind.error, Kind.errorOf, Kind.select:
            n.single = false;
            break;
        case Kind.pipe, Kind.binop, Kind.and, Kind.or, Kind.asOp:
            n.single = n.a.single && n.b.single;
            break;
        case Kind.neg, Kind.has:
            n.single = n.a.single;
            break;
        case Kind.objCons:
            n.single = true;
            foreach (x; n.ks)
                n.single = n.single && x.single;
            foreach (x; n.vs)
                n.single = n.single && x.single;
            break;
        case Kind.ifOp:
            n.single = n.a.single && n.b.single && n.c.single;
            break;
        case Kind.reduce:
            n.single = n.b.single;
            break;
        }
        return n;
    }

    Node mk(Kind k, Node a = null, Node b = null, Node c = null)
    {
        auto n = new Node(k);
        n.a = a;
        n.b = b;
        n.c = c;
        return finish(n);
    }

    Node literal(Value v)
    {
        auto n = new Node(Kind.literal);
        n.lit = v;
        return finish(n);
    }

    Node field(Node target, string name, bool opt = false)
    {
        auto n = new Node(Kind.field);
        n.a = target;
        n.key = new JStr(name);
        n.opt = opt;
        return finish(n);
    }

    int varId(string name)
    {
        if (auto p = name in varIds)
            return *p;
        const id = cast(int) varIds.length;
        varIds[name] = id;
        return id;
    }

    // -- grammar -------------------------------------------------------------

    Node parsePipe()
    {
        auto l = parseComma();
        if (accept(Tok.pipe))
        {
            auto r = parsePipe();
            return mk(Kind.pipe, l, r);
        }
        return l;
    }

    Node parseComma()
    {
        auto l = parseOr();
        while (accept(Tok.comma))
        {
            auto r = parseOr();
            l = mk(Kind.comma, l, r);
        }
        return l;
    }

    Node parseOr()
    {
        auto l = parseAnd();
        while (isIdent("or"))
        {
            ++pos;
            l = mk(Kind.or, l, parseAnd());
        }
        return l;
    }

    Node parseAnd()
    {
        auto l = parseCmp();
        while (isIdent("and"))
        {
            ++pos;
            l = mk(Kind.and, l, parseCmp());
        }
        return l;
    }

    Node binop(BinOp op, Node a, Node b)
    {
        auto n = new Node(Kind.binop);
        n.op = op;
        n.a = a;
        n.b = b;
        return finish(n);
    }

    Node parseCmp()
    {
        auto l = parseAdd();
        BinOp op;
        switch (kind)
        {
        case Tok.eq: op = BinOp.eq; break;
        case Tok.ne: op = BinOp.ne; break;
        case Tok.lt: op = BinOp.lt; break;
        case Tok.le: op = BinOp.le; break;
        case Tok.gt: op = BinOp.gt; break;
        case Tok.ge: op = BinOp.ge; break;
        default: return l;
        }
        ++pos;
        return binop(op, l, parseAdd());
    }

    Node parseAdd()
    {
        auto l = parseMul();
        while (kind == Tok.plus || kind == Tok.minus)
        {
            const op = kind == Tok.plus ? BinOp.add : BinOp.sub;
            ++pos;
            l = binop(op, l, parseMul());
        }
        return l;
    }

    Node parseMul()
    {
        auto l = parseUnary();
        while (kind == Tok.star || kind == Tok.slash || kind == Tok.percent)
        {
            const op = kind == Tok.star ? BinOp.mul : (kind == Tok.slash ? BinOp.div : BinOp.mod);
            ++pos;
            l = binop(op, l, parseUnary());
        }
        return l;
    }

    Node negate(Node x)
    {
        if (x.kind == Kind.literal && x.lit.type == Type.number)
            return literal(Value.makeNumber(-x.lit.num));
        return mk(Kind.neg, x);
    }

    Node parseUnary()
    {
        if (accept(Tok.minus))
            return negate(parseUnary());
        return parsePostfix(true);
    }

    Node parsePostfix(bool allowAs)
    {
        Node t = parsePrimary();
        bool optable = t.kind == Kind.field && t.a.kind == Kind.identity && !t.opt;
        while (true)
        {
            const k = kind;
            if (k == Tok.dot)
            {
                const nx = toks[pos + 1];
                if ((nx.kind == Tok.ident || nx.kind == Tok.str) && nx.start == toks[pos].end)
                {
                    pos += 2;
                    t = field(t, nx.text);
                    optable = true;
                    continue;
                }
                if (nx.kind == Tok.lbrack)
                {
                    ++pos;
                    continue;
                }
                break;
            }
            else if (k == Tok.lbrack)
            {
                ++pos;
                if (accept(Tok.rbrack))
                {
                    t = mk(Kind.iterate, t);
                }
                else if (accept(Tok.colon))
                {
                    auto hi = parsePipe();
                    expect(Tok.rbrack, "']'");
                    t = mk(Kind.slice, t, null, hi);
                }
                else
                {
                    auto e = parsePipe();
                    if (accept(Tok.colon))
                    {
                        Node hi = null;
                        if (kind != Tok.rbrack)
                            hi = parsePipe();
                        expect(Tok.rbrack, "']'");
                        t = mk(Kind.slice, t, e, hi);
                    }
                    else
                    {
                        expect(Tok.rbrack, "']'");
                        t = mk(Kind.index, t, e);
                    }
                }
                optable = true;
            }
            else if (k == Tok.question)
            {
                ++pos;
                if (optable)
                {
                    t.opt = true;
                    finish(t);
                }
                else
                    t = mk(Kind.tryOp, t);
                optable = false;
            }
            else
                break;
        }
        if (allowAs && isIdent("as"))
        {
            ++pos;
            if (kind != Tok.variable)
                throw fail("expected variable after 'as'");
            const id = varId(toks[pos].text);
            ++pos;
            expect(Tok.pipe, "'|' after binding");
            auto body_ = parsePipe();
            auto n = new Node(Kind.asOp);
            n.a = t;
            n.varId = id;
            n.b = body_;
            return finish(n);
        }
        return t;
    }

    Node parsePrimary()
    {
        const tk = toks[pos];
        switch (tk.kind)
        {
        case Tok.dot:
            {
                ++pos;
                const nx = toks[pos];
                if ((nx.kind == Tok.ident || nx.kind == Tok.str) && nx.start == tk.end)
                {
                    ++pos;
                    return field(mk(Kind.identity), nx.text);
                }
                return mk(Kind.identity);
            }
        case Tok.number:
            ++pos;
            return literal(Value.makeNumber(tk.num));
        case Tok.str:
            ++pos;
            return literal(Value.makeString(tk.text));
        case Tok.variable:
            {
                ++pos;
                if ((tk.text in varIds) is null)
                    throw new FilterException("$" ~ tk.text ~ " is not defined", tk.start);
                auto n = new Node(Kind.variable);
                n.varId = varIds[tk.text];
                return finish(n);
            }
        case Tok.lparen:
            {
                ++pos;
                auto e = parsePipe();
                expect(Tok.rparen, "')'");
                // A parenthesised term is no longer a raw suffix: wrap so `(.a)?` means try.
                if (e.kind == Kind.field || e.kind == Kind.index || e.kind == Kind.slice || e.kind == Kind.iterate)
                    return paren(e);
                return e;
            }
        case Tok.lbrack:
            {
                ++pos;
                if (accept(Tok.rbrack))
                    return mk(Kind.arrayCons);
                auto e = parsePipe();
                expect(Tok.rbrack, "']'");
                return mk(Kind.arrayCons, e);
            }
        case Tok.lbrace:
            return parseObject();
        case Tok.ident:
            return parseIdent();
        default:
            throw fail("unexpected token");
        }
    }

    /// Mark a parenthesised suffix chain so that a following `?` is a `try`.
    Node paren(Node e)
    {
        // Pipe with identity is a cheap no-op wrapper that is not "optable".
        return mk(Kind.pipe, mk(Kind.identity), e);
    }

    Node parseIdent()
    {
        const tk = toks[pos];
        ++pos;
        switch (tk.text)
        {
        case "true": return literal(Value.makeBool(true));
        case "false": return literal(Value.makeBool(false));
        case "null": return literal(Value.makeNull);
        case "if":
            return parseIf();
        case "reduce":
            {
                auto src = parsePostfix(false);
                expectKeyword("as");
                if (kind != Tok.variable)
                    throw fail("expected variable");
                const id = varId(toks[pos].text);
                ++pos;
                expect(Tok.lparen, "'('");
                auto init = parsePipe();
                expect(Tok.semi, "';'");
                auto upd = parsePipe();
                expect(Tok.rparen, "')'");
                auto n = new Node(Kind.reduce);
                n.a = src;
                n.varId = id;
                n.b = init;
                n.c = upd;
                return finish(n);
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
        Kind k0;
        bool wantArg = false;
        switch (tk.text)
        {
        case "empty": k0 = Kind.empty; break;
        case "error": k0 = args.length ? Kind.errorOf : Kind.error; wantArg = args.length > 0; break;
        case "not": k0 = Kind.not; break;
        case "length": k0 = Kind.length; break;
        case "keys": k0 = Kind.keys; break;
        case "has": k0 = Kind.has; wantArg = true; break;
        case "type": k0 = Kind.type; break;
        case "add": k0 = Kind.add; break;
        case "select": k0 = Kind.select; wantArg = true; break;
        case "map": k0 = Kind.map; wantArg = true; break;
        case "sort": k0 = Kind.sort; break;
        case "sort_by": k0 = Kind.sortBy; wantArg = true; break;
        case "group_by": k0 = Kind.groupBy; wantArg = true; break;
        case "unique": k0 = Kind.unique; break;
        case "reverse": k0 = Kind.reverse; break;
        case "min": k0 = Kind.min; break;
        case "max": k0 = Kind.max; break;
        case "tostring": k0 = Kind.toStringOp; break;
        case "tonumber": k0 = Kind.toNumberOp; break;
        default:
            throw new FilterException(tk.text ~ "/" ~ cast(char)('0' + args.length) ~ " is not defined", tk.start);
        }
        if (wantArg ? args.length != 1 : args.length != 0)
            throw new FilterException("wrong number of arguments to " ~ tk.text, tk.start);
        return mk(k0, wantArg ? args[0] : null);
    }

    Node parseIf()
    {
        auto cond = parsePipe();
        expectKeyword("then");
        auto then_ = parsePipe();
        Node else_;
        if (isIdent("elif"))
        {
            ++pos;
            else_ = parseIf();
            return mk(Kind.ifOp, cond, then_, else_);
        }
        if (isIdent("else"))
        {
            ++pos;
            else_ = parsePipe();
        }
        else
            else_ = mk(Kind.identity);
        expectKeyword("end");
        return mk(Kind.ifOp, cond, then_, else_);
    }

    Node keyLiteral(string s)
    {
        return literal(Value.makeString(s));
    }

    Node parseObjTerm()
    {
        if (accept(Tok.minus))
            return negate(parseObjTerm());
        return parsePostfix(false);
    }

    Node parseObjVal()
    {
        auto l = parseObjTerm();
        while (accept(Tok.pipe))
            l = mk(Kind.pipe, l, parseObjTerm());
        return l;
    }

    Node parseObject()
    {
        ++pos; // {
        auto n = new Node(Kind.objCons);
        if (!accept(Tok.rbrace))
        {
            while (true)
            {
                const tk = toks[pos];
                if (tk.kind == Tok.ident || tk.kind == Tok.str)
                {
                    ++pos;
                    n.ks ~= keyLiteral(tk.text);
                    if (accept(Tok.colon))
                        n.vs ~= parseObjVal();
                    else
                        n.vs ~= field(mk(Kind.identity), tk.text);
                }
                else if (tk.kind == Tok.variable)
                {
                    ++pos;
                    if ((tk.text in varIds) is null)
                        throw new FilterException("$" ~ tk.text ~ " is not defined", tk.start);
                    auto v = new Node(Kind.variable);
                    v.varId = varIds[tk.text];
                    n.ks ~= keyLiteral(tk.text);
                    n.vs ~= finish(v);
                }
                else if (tk.kind == Tok.lparen)
                {
                    ++pos;
                    n.ks ~= parsePipe();
                    expect(Tok.rparen, "')'");
                    expect(Tok.colon, "':'");
                    n.vs ~= parseObjVal();
                }
                else
                    throw fail("bad object key");
                if (accept(Tok.comma))
                    continue;
                expect(Tok.rbrace, "'}'");
                break;
            }
        }
        n.distinctLiteralKeys = true;
        foreach (i, k; n.ks)
        {
            if (k.kind != Kind.literal || k.lit.type != Type.string)
            {
                n.distinctLiteralKeys = false;
                break;
            }
            foreach (j; 0 .. i)
                if (n.ks[j].kind == Kind.literal && n.ks[j].lit.str.s == k.lit.str.s)
                    n.distinctLiteralKeys = false;
        }
        if (n.distinctLiteralKeys)
            foreach (k; n.ks)
                n.litKeys ~= k.lit.str;
        return finish(n);
    }
}
