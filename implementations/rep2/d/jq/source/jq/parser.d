/**
 * Recursive-descent parser for the jq-subset filter language.
 *
 * Grammar and precedence are documented in SPEC.md; in short, from loosest to
 * tightest: `|`, `,`, `or`, `and`, comparison, `+ -`, `* / %`, unary `-`,
 * postfix suffixes (`.k`, `[e]`, `[]`, `[a:b]`, `?`).
 */
module jq.parser;

import jq.ast;
import jq.errors : FilterSyntaxError;
import jq.lexer;
import jq.value : Kind, Value;

/// Parses a filter program into a syntax tree.
Node parseFilter(string source)
{
    auto p = Parser(tokenize(source));
    auto n = p.parsePipe();
    if (p.cur.kind != TokKind.eof)
        throw new FilterSyntaxError("unexpected '" ~ p.cur.text ~ "'");
    return n;
}

private struct Sig
{
    Builtin fn;
    size_t arity;
}

private immutable Sig[string] builtinTable;

shared static this()
{
    Sig[string] t;
    t["empty"] = Sig(Builtin.empty, 0);
    t["error/0"] = Sig(Builtin.error0, 0);
    t["error/1"] = Sig(Builtin.error1, 1);
    t["not"] = Sig(Builtin.not, 0);
    t["length"] = Sig(Builtin.length, 0);
    t["keys"] = Sig(Builtin.keys, 0);
    t["has"] = Sig(Builtin.has, 1);
    t["type"] = Sig(Builtin.type, 0);
    t["add"] = Sig(Builtin.add, 0);
    t["select"] = Sig(Builtin.select, 1);
    t["map"] = Sig(Builtin.map, 1);
    t["sort"] = Sig(Builtin.sort, 0);
    t["sort_by"] = Sig(Builtin.sortBy, 1);
    t["group_by"] = Sig(Builtin.groupBy, 1);
    t["unique"] = Sig(Builtin.unique, 0);
    t["reverse"] = Sig(Builtin.reverse, 0);
    t["min"] = Sig(Builtin.min, 0);
    t["max"] = Sig(Builtin.max, 0);
    t["tostring"] = Sig(Builtin.tostring, 0);
    t["tonumber"] = Sig(Builtin.tonumber, 0);
    builtinTable = cast(immutable) t;
}

private struct Parser
{
    Token[] toks;
    size_t idx;

    this(Token[] toks)
    {
        this.toks = toks;
    }

    @property Token cur()
    {
        return toks[idx];
    }

    Token peek(size_t n = 1)
    {
        return toks[idx + n < toks.length ? idx + n : toks.length - 1];
    }

    void advance()
    {
        if (idx + 1 < toks.length)
            idx++;
    }

    bool isPunct(string p)
    {
        return cur.kind == TokKind.punct && cur.text == p;
    }

    bool isWord(string w)
    {
        return cur.kind == TokKind.ident && cur.text == w;
    }

    // `.name` / `."name"` with the name directly after the dot (so `. as $x` is not a field).
    bool isFieldDot()
    {
        if (!isPunct("."))
            return false;
        auto nx = peek();
        return (nx.kind == TokKind.ident || nx.kind == TokKind.string) && nx.pos == cur.pos + 1;
    }

    bool acceptPunct(string p)
    {
        if (!isPunct(p))
            return false;
        advance();
        return true;
    }

    void expectPunct(string p)
    {
        if (!acceptPunct(p))
            throw new FilterSyntaxError("expected '" ~ p ~ "' but found '" ~ cur.text ~ "'");
    }

    void expectWord(string w)
    {
        if (!isWord(w))
            throw new FilterSyntaxError("expected '" ~ w ~ "' but found '" ~ cur.text ~ "'");
        advance();
    }

    string expectVariable()
    {
        if (cur.kind != TokKind.variable)
            throw new FilterSyntaxError("expected $variable but found '" ~ cur.text ~ "'");
        auto n = cur.text;
        advance();
        return n;
    }

    Node parsePipe()
    {
        auto lhs = parseComma();
        if (isWord("as"))
        {
            advance();
            auto name = expectVariable();
            expectPunct("|");
            auto n = new Node(NodeKind.as, lhs, parsePipe());
            n.name = name;
            return n;
        }
        if (acceptPunct("|"))
            return new Node(NodeKind.pipe, lhs, parsePipe());
        return lhs;
    }

    Node parseComma()
    {
        auto lhs = parseOr();
        while (acceptPunct(","))
            lhs = new Node(NodeKind.comma, lhs, parseOr());
        return lhs;
    }

    Node parseOr()
    {
        auto lhs = parseAnd();
        while (isWord("or"))
        {
            advance();
            lhs = new Node(NodeKind.or, lhs, parseAnd());
        }
        return lhs;
    }

    Node parseAnd()
    {
        auto lhs = parseCmp();
        while (isWord("and"))
        {
            advance();
            lhs = new Node(NodeKind.and, lhs, parseCmp());
        }
        return lhs;
    }

    Node binary(BinOp op, Node a, Node b)
    {
        auto n = new Node(NodeKind.binary, a, b);
        n.op = op;
        return n;
    }

    Node parseCmp()
    {
        auto lhs = parseAdd();
        if (cur.kind == TokKind.punct)
        {
            BinOp op;
            bool found = true;
            switch (cur.text)
            {
            case "==":
                op = BinOp.eq;
                break;
            case "!=":
                op = BinOp.ne;
                break;
            case "<":
                op = BinOp.lt;
                break;
            case "<=":
                op = BinOp.le;
                break;
            case ">":
                op = BinOp.gt;
                break;
            case ">=":
                op = BinOp.ge;
                break;
            default:
                found = false;
            }
            if (found)
            {
                advance();
                return binary(op, lhs, parseAdd());
            }
        }
        return lhs;
    }

    Node parseAdd()
    {
        auto lhs = parseMul();
        while (true)
        {
            if (acceptPunct("+"))
                lhs = binary(BinOp.add, lhs, parseMul());
            else if (acceptPunct("-"))
                lhs = binary(BinOp.sub, lhs, parseMul());
            else
                return lhs;
        }
    }

    Node parseMul()
    {
        auto lhs = parseUnary();
        while (true)
        {
            if (acceptPunct("*"))
                lhs = binary(BinOp.mul, lhs, parseUnary());
            else if (acceptPunct("/"))
                lhs = binary(BinOp.div, lhs, parseUnary());
            else if (acceptPunct("%"))
                lhs = binary(BinOp.mod, lhs, parseUnary());
            else
                return lhs;
        }
    }

    Node parseUnary()
    {
        if (acceptPunct("-"))
        {
            auto operand = parseUnary();
            if (operand.kind == NodeKind.literal && operand.lit.kind == Kind.number)
            {
                auto n = new Node(NodeKind.literal);
                n.lit = Value.fromNumber(-operand.lit.num);
                return n;
            }
            return new Node(NodeKind.neg, operand);
        }
        return parsePostfix();
    }

    Node literal(Value v)
    {
        auto n = new Node(NodeKind.literal);
        n.lit = v;
        return n;
    }

    Node field(Node term, string name)
    {
        return new Node(NodeKind.index, term, literal(Value.fromString(name)));
    }

    Node parsePostfix()
    {
        Node node;
        // true when `node` was just built by a field/index/iterate/slice suffix,
        // in which case a following `?` applies to that operation only.
        bool suffixable = false;
        if (isFieldDot())
        {
            advance();
            node = field(new Node(NodeKind.identity), cur.text);
            advance();
            suffixable = true;
        }
        else
            node = parsePrimary();

        while (true)
        {
            if (isFieldDot())
            {
                advance();
                node = field(node, cur.text);
                advance();
                suffixable = true;
            }
            else if (isPunct("["))
            {
                advance();
                node = parseBracketSuffix(node);
                suffixable = true;
            }
            else if (isPunct("?"))
            {
                advance();
                if (suffixable)
                    node.optional = true;
                else
                    node = new Node(NodeKind.try_, node);
                suffixable = false;
            }
            else
                return node;
        }
    }

    // After '[' in a suffix position.
    Node parseBracketSuffix(Node term)
    {
        if (acceptPunct("]"))
            return new Node(NodeKind.iterate, term);
        Node from = null;
        if (!isPunct(":"))
        {
            from = parsePipe();
            if (acceptPunct("]"))
                return new Node(NodeKind.index, term, from);
        }
        expectPunct(":");
        Node to = null;
        if (!isPunct("]"))
            to = parsePipe();
        expectPunct("]");
        return new Node(NodeKind.slice, term, from, to);
    }

    Node parsePrimary()
    {
        auto t = cur;
        switch (t.kind)
        {
        case TokKind.number:
            advance();
            return literal(Value.fromNumber(t.num));
        case TokKind.string:
            advance();
            return literal(Value.fromString(t.text));
        case TokKind.variable:
            advance();
            auto n = new Node(NodeKind.variable);
            n.name = t.text;
            return n;
        case TokKind.punct:
            return parsePunctPrimary();
        case TokKind.ident:
            return parseWordPrimary();
        default:
            throw new FilterSyntaxError("unexpected end of filter");
        }
    }

    Node parsePunctPrimary()
    {
        auto t = cur;
        switch (t.text)
        {
        case ".":
            advance();
            return new Node(NodeKind.identity);
        case "(":
            advance();
            auto inner = parsePipe();
            expectPunct(")");
            // Wrap so that a following `?` is a try and never a suffix flag.
            return inner;
        case "[":
            advance();
            if (acceptPunct("]"))
                return new Node(NodeKind.array);
            auto inner = parsePipe();
            expectPunct("]");
            return new Node(NodeKind.array, inner);
        case "{":
            advance();
            return parseObject();
        default:
            throw new FilterSyntaxError("unexpected '" ~ t.text ~ "'");
        }
    }

    Node parseObject()
    {
        auto n = new Node(NodeKind.object);
        if (acceptPunct("}"))
            return n;
        while (true)
        {
            parseEntry(n);
            if (acceptPunct(","))
                continue;
            expectPunct("}");
            return n;
        }
    }

    void parseEntry(Node obj)
    {
        auto t = cur;
        Node key, val;
        if (t.kind == TokKind.variable)
        {
            advance();
            key = literal(Value.fromString(t.text));
            val = new Node(NodeKind.variable);
            val.name = t.text;
        }
        else if (t.kind == TokKind.ident || t.kind == TokKind.string)
        {
            advance();
            key = literal(Value.fromString(t.text));
            if (acceptPunct(":"))
                val = parseObjVal();
            else
                val = field(new Node(NodeKind.identity), t.text);
        }
        else if (isPunct("("))
        {
            advance();
            key = parsePipe();
            expectPunct(")");
            expectPunct(":");
            val = parseObjVal();
        }
        else
            throw new FilterSyntaxError("bad object entry at '" ~ t.text ~ "'");
        obj.keys ~= key;
        obj.values ~= val;
    }

    Node parseObjVal()
    {
        auto lhs = parseObjTerm();
        while (acceptPunct("|"))
            lhs = new Node(NodeKind.pipe, lhs, parseObjTerm());
        return lhs;
    }

    Node parseObjTerm()
    {
        if (acceptPunct("-"))
            return new Node(NodeKind.neg, parseObjTerm());
        return parsePostfix();
    }

    Node parseWordPrimary()
    {
        auto t = cur;
        switch (t.text)
        {
        case "true":
            advance();
            return literal(Value.fromBool(true));
        case "false":
            advance();
            return literal(Value.fromBool(false));
        case "null":
            advance();
            return literal(Value.nil);
        case "if":
            advance();
            return parseIfRest();
        case "reduce":
            advance();
            auto src = parsePostfix();
            expectWord("as");
            auto name = expectVariable();
            expectPunct("(");
            auto init = parsePipe();
            expectPunct(";");
            auto update = parsePipe();
            expectPunct(")");
            auto n = new Node(NodeKind.reduce, src, init, update);
            n.name = name;
            return n;
        default:
            break;
        }
        advance();
        Node[] args;
        if (acceptPunct("("))
        {
            args ~= parsePipe();
            while (acceptPunct(";"))
                args ~= parsePipe();
            expectPunct(")");
        }
        import std.conv : text;

        auto sig = (t.text ~ "/" ~ text(args.length)) in builtinTable;
        if (sig is null)
            sig = t.text in builtinTable;
        if (sig is null || sig.arity != args.length)
            throw new FilterSyntaxError("unknown function " ~ t.text ~ "/" ~ text(args.length));
        auto n = new Node(NodeKind.call);
        n.fn = sig.fn;
        n.args = args;
        return n;
    }

    // After `if` or `elif`.
    Node parseIfRest()
    {
        auto cond = parsePipe();
        expectWord("then");
        auto then = parsePipe();
        Node else_ = null;
        if (isWord("elif"))
        {
            advance();
            else_ = parseIfRest(); // consumes the shared `end`
            return new Node(NodeKind.if_, cond, then, else_);
        }
        if (isWord("else"))
        {
            advance();
            else_ = parsePipe();
        }
        expectWord("end");
        return new Node(NodeKind.if_, cond, then, else_);
    }
}

unittest
{
    import std.exception : assertThrown;

    assert(parseFilter(".a | .b, .c").kind == NodeKind.pipe);
    assert(parseFilter("1, 2 | .").kind == NodeKind.pipe);
    assert(parseFilter(".a?").optional);
    assert(parseFilter("(.a)?").kind == NodeKind.try_);
    assert(parseFilter(".a??").kind == NodeKind.try_);
    assert(parseFilter(".[1:]").kind == NodeKind.slice);
    assert(parseFilter("if . then 1 elif 2 then 3 end").kind == NodeKind.if_);
    assert(parseFilter(".[] as $x | $x").kind == NodeKind.as);
    assertThrown!FilterSyntaxError(parseFilter("foo(1)"));
    assertThrown!FilterSyntaxError(parseFilter(".a |"));
    assertThrown!FilterSyntaxError(parseFilter("[1"));
}
