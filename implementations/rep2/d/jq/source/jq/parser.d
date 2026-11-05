/**
 * Recursive-descent parser for the jq subset (see the grammar in the README).
 *
 * Variables are resolved at parse time to a de Bruijn-style distance in the
 * runtime environment chain, so evaluation never looks anything up by name.
 */
module jq.parser;

import jq.ast;
import jq.lexer;
import jq.value;

/// Parse a filter into an AST. Throws $(REF ParseException, jq,lexer) on bad syntax.
Node parseFilter(string src)
{
    auto p = Parser(tokenize(src));
    auto n = p.parsePipe();
    if (p.cur.kind != Tok.eof)
        throw new ParseException("unexpected token", p.cur.pos);
    return n;
}

private struct Parser
{
    Token[] toks;
    size_t idx;
    string[] vars; // bound variable names, innermost last

    this(Token[] t)
    {
        toks = t;
    }

    ref Token cur()
    {
        return toks[idx];
    }

    ref Token peek(size_t k = 1)
    {
        return toks[idx + k < toks.length ? idx + k : toks.length - 1];
    }

    bool isKw(string w)
    {
        return cur.kind == Tok.ident && cur.text == w;
    }

    ParseException fail(string m)
    {
        return new ParseException(m, cur.pos);
    }

    void expect(Tok k, string what)
    {
        if (cur.kind != k)
            throw fail("expected " ~ what);
        ++idx;
    }

    void expectKw(string w)
    {
        if (!isKw(w))
            throw fail("expected '" ~ w ~ "'");
        ++idx;
    }

    static Node mk(NodeKind k, Node a = null, Node b = null, Node c = null)
    {
        auto n = new Node(k);
        n.a = a;
        n.b = b;
        n.c = c;
        return n;
    }

    static Node litNode(Value v)
    {
        auto n = new Node(NodeKind.literal);
        n.lit = v;
        return finish(n);
    }

    // pipe := postfix "as" "$" IDENT "|" pipe | comma [ "|" pipe ]
    Node parsePipe()
    {
        auto lhs = parseComma();
        if (isKw("as"))
        {
            ++idx;
            if (cur.kind != Tok.var)
                throw fail("expected variable after 'as'");
            string name = cur.text;
            ++idx;
            expect(Tok.pipe, "'|'");
            vars ~= name;
            auto body_ = parsePipe();
            vars.length = vars.length - 1;
            return finish(mk(NodeKind.asBind, lhs, body_));
        }
        if (cur.kind == Tok.pipe)
        {
            ++idx;
            auto rhs = parsePipe();
            return finish(mk(NodeKind.pipe, lhs, rhs));
        }
        return lhs;
    }

    Node parseComma()
    {
        auto lhs = parseOr();
        while (cur.kind == Tok.comma)
        {
            ++idx;
            lhs = finish(mk(NodeKind.comma, lhs, parseOr()));
        }
        return lhs;
    }

    Node parseOr()
    {
        auto lhs = parseAnd();
        while (isKw("or"))
        {
            ++idx;
            lhs = finish(mk(NodeKind.or, lhs, parseAnd()));
        }
        return lhs;
    }

    Node parseAnd()
    {
        auto lhs = parseCmp();
        while (isKw("and"))
        {
            ++idx;
            lhs = finish(mk(NodeKind.and, lhs, parseCmp()));
        }
        return lhs;
    }

    Node binary(BinOp op, Node l, Node r)
    {
        auto n = mk(NodeKind.binary, l, r);
        n.op = op;
        return finish(n);
    }

    Node parseCmp()
    {
        auto lhs = parseAdd();
        BinOp op;
        switch (cur.kind)
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
            return lhs;
        }
        ++idx;
        return binary(op, lhs, parseAdd());
    }

    Node parseAdd()
    {
        auto lhs = parseMul();
        while (cur.kind == Tok.plus || cur.kind == Tok.minus)
        {
            auto op = cur.kind == Tok.plus ? BinOp.add : BinOp.sub;
            ++idx;
            lhs = binary(op, lhs, parseMul());
        }
        return lhs;
    }

    Node parseMul()
    {
        auto lhs = parseUnary();
        while (cur.kind == Tok.star || cur.kind == Tok.slash || cur.kind == Tok.percent)
        {
            auto op = cur.kind == Tok.star ? BinOp.mul : (cur.kind == Tok.slash ? BinOp.div : BinOp.mod);
            ++idx;
            lhs = binary(op, lhs, parseUnary());
        }
        return lhs;
    }

    Node negate(Node x)
    {
        if (x.kind == NodeKind.literal && x.lit.kind == Kind.number)
            return litNode(Value.number(-x.lit.num));
        return finish(mk(NodeKind.neg, x));
    }

    Node parseUnary()
    {
        if (cur.kind == Tok.minus)
        {
            ++idx;
            return negate(parseUnary());
        }
        return parsePostfix();
    }

    Node parsePostfix()
    {
        immutable startsWithPath = cur.kind == Tok.field || (cur.kind == Tok.dot && peek.kind == Tok.str);
        auto t = parsePrimary();
        // `lastPath`: the previous suffix was a path operation that has not yet
        // absorbed a `?`; a `?` then makes that one operation tolerant.
        bool lastPath = startsWithPath;
        while (true)
        {
            switch (cur.kind)
            {
            case Tok.field:
                {
                    auto n = mk(NodeKind.field, t);
                    n.name = new JStr(cur.text);
                    ++idx;
                    t = finish(n);
                    lastPath = true;
                    break;
                }
            case Tok.dot:
                if (peek.kind == Tok.str)
                {
                    ++idx;
                    auto n = mk(NodeKind.field, t);
                    n.name = new JStr(cur.text);
                    ++idx;
                    t = finish(n);
                    lastPath = true;
                    break;
                }
                if (peek.kind == Tok.lbracket)
                {
                    ++idx; // `.a.[0]`
                    break;
                }
                return t;
            case Tok.lbracket:
                t = parseBracket(t);
                lastPath = true;
                break;
            case Tok.question:
                ++idx;
                if (lastPath)
                {
                    t.opt = true;
                    finish(t);
                    lastPath = false;
                }
                else
                    t = finish(mk(NodeKind.tryOp, t));
                break;
            default:
                return t;
            }
        }
    }

    // After "[" has been seen as a suffix of `t`.
    Node parseBracket(Node t)
    {
        ++idx; // [
        if (cur.kind == Tok.rbracket)
        {
            ++idx;
            return finish(mk(NodeKind.iterate, t));
        }
        Node from = null, to = null;
        if (cur.kind == Tok.colon)
        {
            ++idx;
            to = parsePipe();
            expect(Tok.rbracket, "']'");
            return finish(mk(NodeKind.slice, t, null, to));
        }
        from = parsePipe();
        if (cur.kind == Tok.colon)
        {
            ++idx;
            if (cur.kind != Tok.rbracket)
                to = parsePipe();
            expect(Tok.rbracket, "']'");
            return finish(mk(NodeKind.slice, t, from, to));
        }
        expect(Tok.rbracket, "']'");
        return finish(mk(NodeKind.index, t, from));
    }

    int lookupVar(string name)
    {
        foreach_reverse (i, v; vars)
            if (v == name)
                return cast(int)(vars.length - 1 - i);
        throw fail("undefined variable $" ~ name);
    }

    Node parsePrimary()
    {
        auto tk = cur;
        switch (tk.kind)
        {
        case Tok.dot:
            ++idx;
            if (cur.kind == Tok.str)
            {
                auto n = mk(NodeKind.field, finish(new Node(NodeKind.identity)));
                n.name = new JStr(cur.text);
                ++idx;
                return finish(n);
            }
            return finish(new Node(NodeKind.identity));
        case Tok.field:
            {
                ++idx;
                auto n = mk(NodeKind.field, finish(new Node(NodeKind.identity)));
                n.name = new JStr(tk.text);
                return finish(n);
            }
        case Tok.num:
            ++idx;
            return litNode(Value.number(tk.num));
        case Tok.str:
            ++idx;
            return litNode(Value.string_(tk.text));
        case Tok.var:
            {
                ++idx;
                auto n = new Node(NodeKind.variable);
                n.depth = lookupVar(tk.text);
                n.name = new JStr(tk.text);
                return finish(n);
            }
        case Tok.lparen:
            {
                ++idx;
                auto n = parsePipe();
                expect(Tok.rparen, "')'");
                // A parenthesised term is a fresh primary: a following `?` is `try`.
                return n;
            }
        case Tok.lbracket:
            {
                ++idx;
                if (cur.kind == Tok.rbracket)
                {
                    ++idx;
                    return finish(mk(NodeKind.collect));
                }
                auto n = parsePipe();
                expect(Tok.rbracket, "']'");
                return finish(mk(NodeKind.collect, n));
            }
        case Tok.lbrace:
            return parseObject();
        case Tok.ident:
            return parseWord();
        default:
            throw fail("unexpected token");
        }
    }

    Node parseWord()
    {
        auto tk = cur;
        switch (tk.text)
        {
        case "true":
            ++idx;
            return litNode(Value.boolean(true));
        case "false":
            ++idx;
            return litNode(Value.boolean(false));
        case "null":
            ++idx;
            return litNode(Value.nullValue);
        case "if":
            return parseIf();
        case "reduce":
            return parseReduce();
        default:
            return parseCall();
        }
    }

    Node parseIf()
    {
        ++idx; // if / elif
        auto cond = parsePipe();
        expectKw("then");
        auto thenB = parsePipe();
        Node elseB;
        if (isKw("elif"))
        {
            elseB = parseIf(); // consumes through the shared `end`
            return finish(mk(NodeKind.ifElse, cond, thenB, elseB));
        }
        if (isKw("else"))
        {
            ++idx;
            elseB = parsePipe();
        }
        else
            elseB = finish(new Node(NodeKind.identity));
        expectKw("end");
        return finish(mk(NodeKind.ifElse, cond, thenB, elseB));
    }

    Node parseReduce()
    {
        ++idx;
        auto src = parsePostfix();
        expectKw("as");
        if (cur.kind != Tok.var)
            throw fail("expected variable");
        string name = cur.text;
        ++idx;
        expect(Tok.lparen, "'('");
        auto init = parsePipe();
        expect(Tok.semi, "';'");
        vars ~= name;
        auto update = parsePipe();
        vars.length = vars.length - 1;
        expect(Tok.rparen, "')'");
        return finish(mk(NodeKind.reduce, src, init, update));
    }

    static bool lookupBuiltin(string name, out Builtin fn, out int minArgs, out int maxArgs)
    {
        minArgs = maxArgs = 0;
        switch (name)
        {
        case "empty":
            fn = Builtin.empty;
            return true;
        case "error":
            fn = Builtin.error;
            maxArgs = 1;
            return true;
        case "not":
            fn = Builtin.not;
            return true;
        case "length":
            fn = Builtin.length;
            return true;
        case "keys":
            fn = Builtin.keys;
            return true;
        case "has":
            fn = Builtin.has;
            minArgs = maxArgs = 1;
            return true;
        case "type":
            fn = Builtin.type;
            return true;
        case "add":
            fn = Builtin.add;
            return true;
        case "select":
            fn = Builtin.select;
            minArgs = maxArgs = 1;
            return true;
        case "map":
            fn = Builtin.map;
            minArgs = maxArgs = 1;
            return true;
        case "sort":
            fn = Builtin.sort;
            return true;
        case "sort_by":
            fn = Builtin.sortBy;
            minArgs = maxArgs = 1;
            return true;
        case "group_by":
            fn = Builtin.groupBy;
            minArgs = maxArgs = 1;
            return true;
        case "unique":
            fn = Builtin.unique;
            return true;
        case "reverse":
            fn = Builtin.reverse;
            return true;
        case "min":
            fn = Builtin.min;
            return true;
        case "max":
            fn = Builtin.max;
            return true;
        case "tostring":
            fn = Builtin.tostring;
            return true;
        case "tonumber":
            fn = Builtin.tonumber;
            return true;
        default:
            return false;
        }
    }

    Node parseCall()
    {
        auto tk = cur;
        Builtin fn;
        int lo, hi;
        if (!lookupBuiltin(tk.text, fn, lo, hi))
            throw fail("unknown function " ~ tk.text);
        ++idx;
        Node[] args;
        if (cur.kind == Tok.lparen)
        {
            ++idx;
            args ~= parsePipe();
            while (cur.kind == Tok.semi)
            {
                ++idx;
                args ~= parsePipe();
            }
            expect(Tok.rparen, "')'");
        }
        if (cast(int) args.length < lo || cast(int) args.length > hi)
            throw new ParseException(tk.text ~ ": wrong number of arguments", tk.pos);
        auto n = new Node(NodeKind.call);
        n.fn = fn;
        n.args = args;
        return finish(n);
    }

    // objval := objterm { "|" objterm } ; objterm := "-" objterm | postfix
    Node parseObjTerm()
    {
        if (cur.kind == Tok.minus)
        {
            ++idx;
            return negate(parseObjTerm());
        }
        return parsePostfix();
    }

    Node parseObjVal()
    {
        auto lhs = parseObjTerm();
        while (cur.kind == Tok.pipe)
        {
            ++idx;
            lhs = finish(mk(NodeKind.pipe, lhs, parseObjTerm()));
        }
        return lhs;
    }

    Node parseObject()
    {
        ++idx; // {
        auto n = new Node(NodeKind.object);
        if (cur.kind == Tok.rbrace)
        {
            ++idx;
            n.distinctLiteralKeys = true;
            return finish(n);
        }
        while (true)
        {
            ObjEntry e;
            auto tk = cur;
            auto ident = finish(new Node(NodeKind.identity));
            if (tk.kind == Tok.ident || tk.kind == Tok.str)
            {
                ++idx;
                e.litKey = new JStr(tk.text);
                if (cur.kind == Tok.colon)
                {
                    ++idx;
                    e.val = parseObjVal();
                }
                else
                {
                    auto f = mk(NodeKind.field, ident);
                    f.name = e.litKey;
                    e.val = finish(f);
                }
            }
            else if (tk.kind == Tok.var)
            {
                ++idx;
                e.litKey = new JStr(tk.text);
                auto v = new Node(NodeKind.variable);
                v.depth = lookupVar(tk.text);
                v.name = e.litKey;
                e.val = finish(v);
            }
            else if (tk.kind == Tok.lparen)
            {
                ++idx;
                e.key = parsePipe();
                expect(Tok.rparen, "')'");
                expect(Tok.colon, "':'");
                e.val = parseObjVal();
            }
            else
                throw fail("bad object key");
            n.entries ~= e;
            if (cur.kind == Tok.comma)
            {
                ++idx;
                continue;
            }
            expect(Tok.rbrace, "'}'");
            break;
        }
        bool distinct = true;
        foreach (i, ref e; n.entries)
        {
            if (e.key !is null)
                distinct = false;
            else
                foreach (ref o; n.entries[0 .. i])
                    if (o.key is null && o.litKey.s == e.litKey.s)
                        distinct = false;
        }
        n.distinctLiteralKeys = distinct;
        return finish(n);
    }
}
