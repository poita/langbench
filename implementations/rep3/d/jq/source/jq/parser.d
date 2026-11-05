/// Lexer and recursive-descent parser for the filter language.
module jq.parser;

import jq.ast;
import jq.errors;
import jq.json : putUtf8;
import jq.buffer;
import jq.number;
import jq.value;

/// Compile filter text into a `Program`. Throws `ParseError`.
Program compile(string filter)
{
    auto p = new Parser(filter);
    return new Program(p.parseAll());
}

private enum T : ubyte
{
    eof, num, str, ident, field, var,
    dot, lbrack, rbrack, lparen, rparen, lbrace, rbrace, comma, pipe, colon,
    semi, question, plus, minus, star, slash, percent,
    eq, ne, lt, le, gt, ge,
}

private struct Tok
{
    T kind;
    string text; // identifier / string contents / field or variable name
    double num;
}

private bool isIdStart(char c) pure nothrow @nogc @safe
{
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_';
}

private bool isIdChar(char c) pure nothrow @nogc @safe
{
    return isIdStart(c) || (c >= '0' && c <= '9');
}

private Tok[] lex(string s)
{
    Tok[] toks;
    size_t i = 0;
    while (i < s.length)
    {
        immutable c = s[i];
        if (c == ' ' || c == '\t' || c == '\n' || c == '\r')
        {
            ++i;
            continue;
        }
        if (c == '#')
        {
            while (i < s.length && s[i] != '\n')
                ++i;
            continue;
        }
        if (c >= '0' && c <= '9')
        {
            size_t j = i;
            while (j < s.length && s[j] >= '0' && s[j] <= '9')
                ++j;
            if (j + 1 < s.length && s[j] == '.' && s[j + 1] >= '0' && s[j + 1] <= '9')
            {
                ++j;
                while (j < s.length && s[j] >= '0' && s[j] <= '9')
                    ++j;
            }
            toks ~= Tok(T.num, null, parseNumber(s[i .. j]));
            i = j;
            continue;
        }
        if (isIdStart(c))
        {
            size_t j = i;
            while (j < s.length && isIdChar(s[j]))
                ++j;
            toks ~= Tok(T.ident, s[i .. j]);
            i = j;
            continue;
        }
        if (c == '$')
        {
            size_t j = i + 1;
            while (j < s.length && isIdChar(s[j]))
                ++j;
            if (j == i + 1)
                throw new ParseError("bad variable");
            toks ~= Tok(T.var, s[i + 1 .. j]);
            i = j;
            continue;
        }
        if (c == '.')
        {
            if (i + 1 < s.length && isIdStart(s[i + 1]))
            {
                size_t j = i + 1;
                while (j < s.length && isIdChar(s[j]))
                    ++j;
                toks ~= Tok(T.field, s[i + 1 .. j]);
                i = j;
            }
            else
            {
                toks ~= Tok(T.dot);
                ++i;
            }
            continue;
        }
        if (c == '"')
        {
            i = lexString(s, i, toks);
            continue;
        }
        immutable nx = i + 1 < s.length ? s[i + 1] : '\0';
        T k;
        size_t w = 1;
        switch (c)
        {
        case '[': k = T.lbrack; break;
        case ']': k = T.rbrack; break;
        case '(': k = T.lparen; break;
        case ')': k = T.rparen; break;
        case '{': k = T.lbrace; break;
        case '}': k = T.rbrace; break;
        case ',': k = T.comma; break;
        case '|': k = T.pipe; break;
        case ':': k = T.colon; break;
        case ';': k = T.semi; break;
        case '?': k = T.question; break;
        case '+': k = T.plus; break;
        case '-': k = T.minus; break;
        case '*': k = T.star; break;
        case '/': k = T.slash; break;
        case '%': k = T.percent; break;
        case '=':
            if (nx != '=')
                throw new ParseError("unsupported operator '='");
            k = T.eq; w = 2; break;
        case '!':
            if (nx != '=')
                throw new ParseError("unexpected '!'");
            k = T.ne; w = 2; break;
        case '<':
            if (nx == '=') { k = T.le; w = 2; } else k = T.lt;
            break;
        case '>':
            if (nx == '=') { k = T.ge; w = 2; } else k = T.gt;
            break;
        default:
            throw new ParseError("unexpected character in filter");
        }
        toks ~= Tok(k);
        i += w;
    }
    toks ~= Tok(T.eof);
    return toks;
}

private uint hex4(string s, size_t i)
{
    if (i + 4 > s.length)
        throw new ParseError("bad \\u escape");
    uint v = 0;
    foreach (k; 0 .. 4)
    {
        immutable c = s[i + k];
        uint d;
        if (c >= '0' && c <= '9') d = c - '0';
        else if (c >= 'a' && c <= 'f') d = c - 'a' + 10;
        else if (c >= 'A' && c <= 'F') d = c - 'A' + 10;
        else throw new ParseError("bad \\u escape");
        v = v * 16 + d;
    }
    return v;
}

private size_t lexString(string s, size_t i, ref Tok[] toks)
{
    ++i;
    Buf b;
    while (i < s.length)
    {
        immutable c = s[i];
        if (c == '"')
        {
            toks ~= Tok(T.str, b.slice.idup);
            return i + 1;
        }
        if (c != '\\')
        {
            b.put(c);
            ++i;
            continue;
        }
        ++i;
        if (i >= s.length)
            break;
        immutable e = s[i++];
        switch (e)
        {
        case '"': b.put('"'); break;
        case '\\': b.put('\\'); break;
        case '/': b.put('/'); break;
        case 'b': b.put('\b'); break;
        case 'f': b.put('\f'); break;
        case 'n': b.put('\n'); break;
        case 'r': b.put('\r'); break;
        case 't': b.put('\t'); break;
        case 'u':
            {
                uint cp = hex4(s, i);
                i += 4;
                if (cp >= 0xD800 && cp <= 0xDBFF && i + 1 < s.length && s[i] == '\\' && s[i + 1] == 'u')
                {
                    immutable lo = hex4(s, i + 2);
                    if (lo >= 0xDC00 && lo <= 0xDFFF)
                    {
                        cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
                        i += 6;
                    }
                }
                putUtf8(b, cp);
                break;
            }
        default:
            throw new ParseError("bad escape in string literal");
        }
    }
    throw new ParseError("unterminated string literal");
}

private final class Parser
{
    Tok[] toks;
    size_t p;
    int[string] varIds;
    bool primaryIsPath;

    this(string src)
    {
        toks = lex(src);
    }

    Node parseAll()
    {
        auto n = parsePipe();
        if (cur.kind != T.eof)
            fail("unexpected token");
        return n;
    }

    @property ref Tok cur() { return toks[p]; }

    void fail(string m)
    {
        throw new ParseError(m);
    }

    bool isKw(string w)
    {
        return cur.kind == T.ident && cur.text == w;
    }

    void expect(T k, string what)
    {
        if (cur.kind != k)
            fail("expected " ~ what);
        ++p;
    }

    void expectKw(string w)
    {
        if (!isKw(w))
            fail("expected " ~ w);
        ++p;
    }

    int varId(string name)
    {
        if (auto q = name in varIds)
            return *q;
        immutable id = cast(int) varIds.length;
        varIds[name] = id;
        return id;
    }

    // ---- node constructors (they compute `simple`) ----

    static bool simp(Node n)
    {
        return n is null || n.simple;
    }

    static Node mk(K k, Node a = null, Node b = null, Node c = null)
    {
        auto n = new Node(k);
        n.a = a;
        n.b = b;
        n.c = c;
        refresh(n);
        return n;
    }

    static void refresh(Node n)
    {
        final switch (n.kind)
        {
        case K.identity, K.literal, K.variable:
            n.simple = true; break;
        case K.field, K.iterate:
            n.simple = n.kind == K.field && !n.opt && simp(n.a); break;
        case K.index:
            n.simple = !n.opt && simp(n.a) && simp(n.b); break;
        case K.slice:
            n.simple = !n.opt && simp(n.a) && simp(n.b) && simp(n.c); break;
        case K.tryOp, K.comma, K.ifOp, K.asOp, K.reduce:
            n.simple = false; break;
        case K.neg:
            n.simple = simp(n.a); break;
        case K.bin, K.and, K.or, K.pipe:
            n.simple = simp(n.a) && simp(n.b); break;
        case K.array:
            n.simple = true; break;
        case K.object:
            {
                bool s = true;
                foreach (e; n.entries)
                    s = s && simp(e.keyExpr) && simp(e.val);
                n.simple = s;
                break;
            }
        case K.call:
            switch (n.builtin)
            {
            case B.not, B.length, B.keys, B.type, B.add, B.map, B.sort, B.sortBy,
                    B.groupBy, B.unique, B.reverse, B.min, B.max, B.tostring, B.tonumber:
                n.simple = true; break;
            case B.has:
                n.simple = simp(n.args[0]); break;
            default:
                n.simple = false;
            }
            break;
        }
    }

    static Node withTerm(K k, Node term)
    {
        auto n = new Node(k);
        n.a = (term !is null && term.kind == K.identity) ? null : term;
        return n;
    }

    static Node mkLit(Value v)
    {
        auto n = new Node(K.literal);
        n.lit = v;
        refresh(n);
        return n;
    }

    // ---- grammar ----

    Node parsePipe()
    {
        auto l = parseComma();
        if (cur.kind == T.pipe)
        {
            ++p;
            auto r = parsePipe();
            return mk(K.pipe, l, r);
        }
        return l;
    }

    Node parseComma()
    {
        auto l = parseOr();
        while (cur.kind == T.comma)
        {
            ++p;
            l = mk(K.comma, l, parseOr());
        }
        return l;
    }

    Node parseOr()
    {
        auto l = parseAnd();
        while (isKw("or"))
        {
            ++p;
            l = mk(K.or, l, parseAnd());
        }
        return l;
    }

    Node parseAnd()
    {
        auto l = parseCmp();
        while (isKw("and"))
        {
            ++p;
            l = mk(K.and, l, parseCmp());
        }
        return l;
    }

    Node parseCmp()
    {
        auto l = parseAdd();
        BinOp op;
        switch (cur.kind)
        {
        case T.eq: op = BinOp.eq; break;
        case T.ne: op = BinOp.ne; break;
        case T.lt: op = BinOp.lt; break;
        case T.le: op = BinOp.le; break;
        case T.gt: op = BinOp.gt; break;
        case T.ge: op = BinOp.ge; break;
        default: return l;
        }
        ++p;
        auto r = parseAdd();
        auto n = mk(K.bin, l, r);
        n.op = op;
        return n;
    }

    Node parseAdd()
    {
        auto l = parseMul();
        for (;;)
        {
            BinOp op;
            if (cur.kind == T.plus) op = BinOp.add;
            else if (cur.kind == T.minus) op = BinOp.sub;
            else return l;
            ++p;
            auto n = mk(K.bin, l, parseMul());
            n.op = op;
            l = n;
        }
    }

    Node parseMul()
    {
        auto l = parseUnary();
        for (;;)
        {
            BinOp op;
            if (cur.kind == T.star) op = BinOp.mul;
            else if (cur.kind == T.slash) op = BinOp.div;
            else if (cur.kind == T.percent) op = BinOp.mod;
            else return l;
            ++p;
            auto n = mk(K.bin, l, parseUnary());
            n.op = op;
            l = n;
        }
    }

    Node parseUnary()
    {
        if (cur.kind == T.minus)
        {
            ++p;
            return negate(parseUnary());
        }
        return parsePostfix(true);
    }

    static Node negate(Node x)
    {
        if (x.kind == K.literal && x.lit.isNumber)
            return mkLit(mkNum(-x.lit.num));
        return mk(K.neg, x);
    }

    Node parsePostfix(bool allowAs)
    {
        auto t = parsePrimary();
        bool path = primaryIsPath;
        for (;;)
        {
            switch (cur.kind)
            {
            case T.field:
                {
                    auto n = withTerm(K.field, t);
                    n.str = cur.text;
                    ++p;
                    refresh(n);
                    t = n;
                    path = true;
                    continue;
                }
            case T.dot:
                {
                    // `.` followed by a string or `[`
                    if (toks[p + 1].kind == T.str)
                    {
                        auto n = withTerm(K.field, t);
                        n.str = toks[p + 1].text;
                        p += 2;
                        refresh(n);
                        t = n;
                        path = true;
                        continue;
                    }
                    if (toks[p + 1].kind == T.lbrack)
                    {
                        ++p;
                        continue;
                    }
                    fail("unexpected '.'");
                    break;
                }
            case T.lbrack:
                t = parseBracket(t);
                path = true;
                continue;
            case T.question:
                {
                    ++p;
                    if (path && !t.opt && (t.kind == K.field || t.kind == K.index
                            || t.kind == K.slice || t.kind == K.iterate))
                    {
                        t.opt = true;
                        refresh(t);
                    }
                    else
                    {
                        t = mk(K.tryOp, t);
                        path = false;
                    }
                    continue;
                }
            default:
                break;
            }
            break;
        }
        if (allowAs && isKw("as"))
        {
            ++p;
            if (cur.kind != T.var)
                fail("expected variable after 'as'");
            immutable id = varId(cur.text);
            auto name = cur.text;
            ++p;
            expect(T.pipe, "'|'");
            auto body_ = parsePipe();
            auto n = mk(K.asOp, t, body_);
            n.id = id;
            n.str = name;
            return n;
        }
        return t;
    }

    /// Parse a `[...]` suffix applied to term `t`.
    Node parseBracket(Node t)
    {
        ++p; // [
        if (cur.kind == T.rbrack)
        {
            ++p;
            auto n = withTerm(K.iterate, t);
            refresh(n);
            return n;
        }
        Node from, to;
        bool isSlice = false;
        if (cur.kind == T.colon)
        {
            isSlice = true;
        }
        else
        {
            from = parsePipe();
            if (cur.kind == T.colon)
                isSlice = true;
        }
        if (isSlice)
        {
            ++p; // :
            if (cur.kind != T.rbrack)
                to = parsePipe();
            expect(T.rbrack, "']'");
            auto n = withTerm(K.slice, t);
            n.b = from;
            n.c = to;
            refresh(n);
            return n;
        }
        expect(T.rbrack, "']'");
        auto n = withTerm(K.index, t);
        n.b = from;
        refresh(n);
        return n;
    }

    Node parsePrimary()
    {
        primaryIsPath = false;
        auto tk = cur;
        switch (tk.kind)
        {
        case T.num:
            ++p;
            return mkLit(mkNum(tk.num));
        case T.str:
            ++p;
            return mkLit(mkStr(tk.text));
        case T.var:
            {
                ++p;
                auto n = new Node(K.variable);
                n.id = varId(tk.text);
                n.str = tk.text;
                refresh(n);
                return n;
            }
        case T.field:
            {
                ++p;
                auto n = new Node(K.field);
                n.str = tk.text;
                refresh(n);
                primaryIsPath = true;
                return n;
            }
        case T.dot:
            {
                ++p;
                if (cur.kind == T.str)
                {
                    auto n = new Node(K.field);
                    n.str = cur.text;
                    ++p;
                    refresh(n);
                    primaryIsPath = true;
                    return n;
                }
                auto n = new Node(K.identity);
                refresh(n);
                return n;
            }
        case T.lparen:
            {
                ++p;
                auto e = parsePipe();
                expect(T.rparen, "')'");
                primaryIsPath = false;
                return e;
            }
        case T.lbrack:
            {
                ++p;
                Node e;
                if (cur.kind != T.rbrack)
                    e = parsePipe();
                expect(T.rbrack, "']'");
                primaryIsPath = false;
                return mk(K.array, e);
            }
        case T.lbrace:
            {
                auto o = parseObject();
                primaryIsPath = false;
                return o;
            }
        case T.ident:
            {
                auto r = parseIdent();
                primaryIsPath = false;
                return r;
            }
        default:
            fail("unexpected token");
            assert(0);
        }
    }

    Node parseIdent()
    {
        auto name = cur.text;
        ++p;
        switch (name)
        {
        case "true":
            return mkLit(mkBool(true));
        case "false":
            return mkLit(mkBool(false));
        case "null":
            return mkLit(mkNull());
        case "if":
            return parseIf();
        case "reduce":
            {
                auto src = parsePostfix(false);
                expectKw("as");
                if (cur.kind != T.var)
                    fail("expected variable");
                immutable id = varId(cur.text);
                ++p;
                expect(T.lparen, "'('");
                auto init = parsePipe();
                expect(T.semi, "';'");
                auto upd = parsePipe();
                expect(T.rparen, "')'");
                auto n = mk(K.reduce, src, init, upd);
                n.id = id;
                return n;
            }
        default:
            break;
        }
        Node[] args;
        if (cur.kind == T.lparen)
        {
            ++p;
            args ~= parsePipe();
            while (cur.kind == T.semi)
            {
                ++p;
                args ~= parsePipe();
            }
            expect(T.rparen, "')'");
        }
        auto n = new Node(K.call);
        n.args = args;
        n.builtin = builtinFor(name, args.length);
        refresh(n);
        return n;
    }

    static B builtinFor(string name, size_t nargs)
    {
        static struct Def { string name; B b; size_t nargs; }
        static immutable Def[] defs = [
            Def("empty", B.empty, 0), Def("error", B.error, 0), Def("error", B.error, 1),
            Def("not", B.not, 0), Def("length", B.length, 0), Def("keys", B.keys, 0),
            Def("has", B.has, 1), Def("type", B.type, 0), Def("add", B.add, 0),
            Def("select", B.select, 1), Def("map", B.map, 1), Def("sort", B.sort, 0),
            Def("sort_by", B.sortBy, 1), Def("group_by", B.groupBy, 1),
            Def("unique", B.unique, 0), Def("reverse", B.reverse, 0),
            Def("min", B.min, 0), Def("max", B.max, 0), Def("tostring", B.tostring, 0),
            Def("tonumber", B.tonumber, 0),
        ];
        foreach (d; defs)
            if (d.name == name && d.nargs == nargs)
                return d.b;
        throw new ParseError("unknown function " ~ name);
    }

    Node parseIf()
    {
        auto cond = parsePipe();
        expectKw("then");
        auto thenB = parsePipe();
        Node elseB;
        if (isKw("elif"))
        {
            ++p;
            elseB = parseIf(); // consumes through `end`
            return mkIf(cond, thenB, elseB);
        }
        if (isKw("else"))
        {
            ++p;
            elseB = parsePipe();
        }
        expectKw("end");
        return mkIf(cond, thenB, elseB);
    }

    static Node mkIf(Node c, Node t, Node e)
    {
        auto n = mk(K.ifOp, c, t, e);
        return n;
    }

    Node parseObjTerm()
    {
        if (cur.kind == T.minus)
        {
            ++p;
            return negate(parseObjTerm());
        }
        return parsePostfix(false);
    }

    Node parseObjVal()
    {
        auto l = parseObjTerm();
        while (cur.kind == T.pipe)
        {
            ++p;
            l = mk(K.pipe, l, parseObjTerm());
        }
        return l;
    }

    Node parseObject()
    {
        ++p; // {
        ObjEntry[] ents;
        if (cur.kind == T.rbrace)
        {
            ++p;
        }
        else
        {
            for (;;)
            {
                ObjEntry e;
                auto tk = cur;
                if (tk.kind == T.ident || tk.kind == T.str)
                {
                    ++p;
                    e.keyLit = tk.text;
                    if (cur.kind == T.colon)
                    {
                        ++p;
                        e.val = parseObjVal();
                    }
                    else
                    {
                        auto f = new Node(K.field);
                        f.str = tk.text;
                        refresh(f);
                        e.val = f;
                    }
                }
                else if (tk.kind == T.var)
                {
                    ++p;
                    e.keyLit = tk.text;
                    auto v = new Node(K.variable);
                    v.id = varId(tk.text);
                    v.str = tk.text;
                    refresh(v);
                    e.val = v;
                }
                else if (tk.kind == T.lparen)
                {
                    ++p;
                    e.keyExpr = parsePipe();
                    expect(T.rparen, "')'");
                    expect(T.colon, "':'");
                    e.val = parseObjVal();
                }
                else if (tk.kind == T.num)
                {
                    fail("numeric object key");
                }
                else
                    fail("bad object entry");
                ents ~= e;
                if (cur.kind == T.comma)
                {
                    ++p;
                    continue;
                }
                break;
            }
            expect(T.rbrace, "'}'");
        }
        auto n = new Node(K.object);
        n.entries = ents;
        bool distinct = true;
        foreach (i, e; ents)
        {
            if (e.keyExpr !is null)
                distinct = false;
            else
                foreach (j; 0 .. i)
                    if (ents[j].keyExpr is null && ents[j].keyLit == e.keyLit)
                        distinct = false;
        }
        n.litDistinct = distinct;
        refresh(n);
        return n;
    }
}
