/// Recursive-descent parser producing the syntax tree of one template.
module jtemplate.parser;

import jtemplate.ast;
import jtemplate.errors;
import jtemplate.lexer;
import jtemplate.value;

/// Map a filter name to its [FilterId] (`unknown` if it is not a filter).
FilterId filterId(const(char)[] name) pure nothrow @safe @nogc
{
    switch (name)
    {
        case "upper":   return FilterId.upper;
        case "lower":   return FilterId.lower;
        case "trim":    return FilterId.trim;
        case "escape":  return FilterId.escape;
        case "replace": return FilterId.replace;
        case "length":  return FilterId.length;
        case "int":     return FilterId.int_;
        case "join":    return FilterId.join;
        case "first":   return FilterId.first;
        case "last":    return FilterId.last;
        case "reverse": return FilterId.reverse;
        case "sort":    return FilterId.sort;
        case "default": return FilterId.default_;
        default:        return FilterId.unknown;
    }
}

/// Lex, parse and check a template.
///
/// Throws a syntax [TemplateError] for any lexical or grammatical problem;
/// only when the whole template parses are filter names checked, so a
/// syntax error always wins over an unknown filter.
Template parseTemplate(string name, string source)
{
    auto p = new Parser(lex(source));
    auto t = p.parse();
    t.name = name;
    if (p.sawUnknownFilter)
        throw filterError("unknown filter");
    return t;
}

private final class Parser
{
    LexResult lexed;
    size_t segIndex;
    Token[] cur;        // tokens of the tag being parsed
    size_t ti;
    bool sawUnknownFilter;
    bool sawExtends;
    uint nesting;       // depth of enclosing if/for/block/macro
    BlockNode[string] blocks;

    // Terminator seen by parseBody: the keyword of the stmt tag that ended it.
    string endKeyword;

    this(LexResult lexed) { this.lexed = lexed; }

    Template parse()
    {
        auto t = new Template;
        t.body = parseBody();
        if (segIndex < lexed.segments.length || endKeyword !is null)
            throw syntaxError("unexpected '" ~ endKeyword ~ "'");
        t.blocks = blocks;
        return t;
    }

    // ---- token access ------------------------------------------------------

    @property Token peek() { return ti < cur.length ? cur[ti] : Token(Tok.eof); }
    Tok peekType() { return ti < cur.length ? cur[ti].type : Tok.eof; }
    Tok peekType(size_t ahead) { return ti + ahead < cur.length ? cur[ti + ahead].type : Tok.eof; }
    Token next() { auto t = peek; if (ti < cur.length) ++ti; return t; }

    bool accept(Tok t)
    {
        if (peekType == t) { ++ti; return true; }
        return false;
    }

    void expect(Tok t, string what)
    {
        if (!accept(t))
            throw syntaxError("expected " ~ what);
    }

    string expectName(string what)
    {
        if (peekType != Tok.name)
            throw syntaxError("expected " ~ what);
        return next().text;
    }

    void expectEnd()
    {
        if (ti != cur.length)
            throw syntaxError("unexpected token in tag");
    }

    void setTag(Segment seg)
    {
        cur = lexed.tokens[seg.tokBegin .. seg.tokEnd];
        ti = 0;
    }

    // ---- statements --------------------------------------------------------

    /// Parse nodes until a closing keyword (`elif`, `else`, `end*`) or the
    /// end of the template. On a closing keyword, `endKeyword` is set and
    /// the tag's tokens are left in `cur` (after the keyword).
    Node[] parseBody()
    {
        Node[] nodes;
        endKeyword = null;
        while (segIndex < lexed.segments.length)
        {
            auto seg = lexed.segments[segIndex++];
            final switch (seg.kind)
            {
                case SegKind.text:
                    nodes ~= new TextNode(seg.text);
                    break;
                case SegKind.print:
                    setTag(seg);
                    auto e = parseExpr();
                    expectEnd();
                    nodes ~= new PrintNode(e);
                    break;
                case SegKind.stmt:
                    setTag(seg);
                    if (peekType != Tok.name)
                        throw syntaxError("expected a statement keyword");
                    auto kw = next().text;
                    switch (kw)
                    {
                        case "elif", "else", "endif", "endfor", "endmacro", "endblock":
                            endKeyword = kw;
                            return nodes;
                        case "if":      nodes ~= parseIf(); break;
                        case "for":     nodes ~= parseFor(); break;
                        case "set":     nodes ~= parseSet(); break;
                        case "macro":   nodes ~= parseMacro(); break;
                        case "include": nodes ~= parseInclude(); break;
                        case "extends": nodes ~= parseExtends(); break;
                        case "block":   nodes ~= parseBlock(); break;
                        default: throw syntaxError("unknown statement '" ~ kw ~ "'");
                    }
                    break;
            }
        }
        return nodes;
    }

    /// Parse a nested body and require that it ends with a closing keyword.
    Node[] parseNested()
    {
        ++nesting;
        auto body = parseBody();
        --nesting;
        if (endKeyword is null)
            throw syntaxError("missing end tag");
        return body;
    }

    Node parseIf()
    {
        auto node = new IfNode;
        node.conds ~= parseExpr();
        expectEnd();
        node.bodies ~= parseNested();
        for (;;)
        {
            switch (endKeyword)
            {
                case "elif":
                    node.conds ~= parseExpr();
                    expectEnd();
                    node.bodies ~= parseNested();
                    continue;
                case "else":
                    expectEnd();
                    node.elseBody = parseNested();
                    if (endKeyword != "endif")
                        throw syntaxError("expected endif");
                    goto case "endif";
                case "endif":
                    expectEnd();
                    endKeyword = null;
                    return node;
                default:
                    throw syntaxError("expected endif");
            }
        }
        assert(0);
    }

    Node parseFor()
    {
        auto var = expectName("loop variable");
        expect(Tok.kwIn, "'in'");
        auto iter = parseExpr();
        expectEnd();
        auto node = new ForNode(var, iter);
        node.body = parseNested();
        if (endKeyword == "else")
        {
            expectEnd();
            node.elseBody = parseNested();
        }
        if (endKeyword != "endfor")
            throw syntaxError("expected endfor");
        expectEnd();
        endKeyword = null;
        return node;
    }

    Node parseSet()
    {
        auto name = expectName("variable name");
        expect(Tok.assign, "'='");
        auto e = parseExpr();
        expectEnd();
        return new SetNode(name, e);
    }

    Node parseMacro()
    {
        auto node = new MacroNode(expectName("macro name"));
        expect(Tok.lparen, "'('");
        if (peekType != Tok.rparen)
        {
            for (;;)
            {
                auto p = expectName("parameter name");
                foreach (q; node.params)
                    if (q == p) throw syntaxError("duplicate parameter");
                node.params ~= p;
                node.defaults ~= accept(Tok.assign) ? parseExpr() : null;
                if (!accept(Tok.comma)) break;
            }
        }
        expect(Tok.rparen, "')'");
        expectEnd();
        node.body = parseNested();
        if (endKeyword != "endmacro")
            throw syntaxError("expected endmacro");
        expectEnd();
        endKeyword = null;
        return node;
    }

    Node parseInclude()
    {
        auto e = parseExpr();
        expectEnd();
        return new IncludeNode(e);
    }

    Node parseExtends()
    {
        if (nesting != 0 || sawExtends)
            throw syntaxError("misplaced extends");
        sawExtends = true;
        auto e = parseExpr();
        expectEnd();
        return new ExtendsNode(e);
    }

    Node parseBlock()
    {
        auto name = expectName("block name");
        expectEnd();
        if (name in blocks)
            throw syntaxError("duplicate block '" ~ name ~ "'");
        auto node = new BlockNode(name);
        blocks[name] = node;
        node.body = parseNested();
        if (endKeyword != "endblock")
            throw syntaxError("expected endblock");
        if (peekType == Tok.name)
        {
            if (next().text != name)
                throw syntaxError("endblock name mismatch");
        }
        expectEnd();
        endKeyword = null;
        return node;
    }

    // ---- expressions -------------------------------------------------------

    Expr parseExpr() { return parseOr(); }

    Expr parseOr()
    {
        auto lhs = parseAnd();
        while (accept(Tok.kwOr))
            lhs = new LogicExpr(ExprKind.or, lhs, parseAnd());
        return lhs;
    }

    Expr parseAnd()
    {
        auto lhs = parseNot();
        while (accept(Tok.kwAnd))
            lhs = new LogicExpr(ExprKind.and, lhs, parseNot());
        return lhs;
    }

    Expr parseNot()
    {
        if (accept(Tok.kwNot))
            return new UnaryExpr(ExprKind.not, parseNot());
        return parseCompare();
    }

    Expr parseCompare()
    {
        auto first = parseAdditive();
        CmpOp[] ops;
        Expr[] rest;
        for (;;)
        {
            CmpOp op;
            switch (peekType)
            {
                case Tok.eq: op = CmpOp.eq; break;
                case Tok.ne: op = CmpOp.ne; break;
                case Tok.lt: op = CmpOp.lt; break;
                case Tok.le: op = CmpOp.le; break;
                case Tok.gt: op = CmpOp.gt; break;
                case Tok.ge: op = CmpOp.ge; break;
                case Tok.kwIn: op = CmpOp.in_; break;
                case Tok.kwNot:
                    if (peekType(1) != Tok.kwIn) goto done;
                    ++ti;
                    op = CmpOp.notIn;
                    break;
                default: goto done;
            }
            ++ti;
            ops ~= op;
            rest ~= parseAdditive();
        }
    done:
        if (ops.length == 0)
            return first;
        return new CompareExpr(first, ops, rest);
    }

    Expr parseAdditive()
    {
        auto lhs = parseConcat();
        for (;;)
        {
            if (accept(Tok.plus))       lhs = new BinaryExpr(BinOp.add, lhs, parseConcat());
            else if (accept(Tok.minus)) lhs = new BinaryExpr(BinOp.sub, lhs, parseConcat());
            else return lhs;
        }
    }

    Expr parseConcat()
    {
        auto lhs = parseTerm();
        while (accept(Tok.tilde))
            lhs = new BinaryExpr(BinOp.concat, lhs, parseTerm());
        return lhs;
    }

    Expr parseTerm()
    {
        auto lhs = parsePower();
        for (;;)
        {
            BinOp op;
            switch (peekType)
            {
                case Tok.star:     op = BinOp.mul; break;
                case Tok.slash:    op = BinOp.div; break;
                case Tok.floorDiv: op = BinOp.floorDiv; break;
                case Tok.percent:  op = BinOp.mod; break;
                default: return lhs;
            }
            ++ti;
            lhs = new BinaryExpr(op, lhs, parsePower());
        }
    }

    Expr parsePower()
    {
        auto lhs = parseFiltered();
        while (accept(Tok.pow))
            lhs = new BinaryExpr(BinOp.pow, lhs, parseFiltered());
        return lhs;
    }

    Expr parseFiltered()
    {
        auto e = parseUnary();
        for (;;)
        {
            if (accept(Tok.pipe))
            {
                auto name = expectName("filter name");
                Expr[] args;
                if (accept(Tok.lparen))
                {
                    if (peekType != Tok.rparen)
                    {
                        do args ~= parseExpr(); while (accept(Tok.comma));
                    }
                    expect(Tok.rparen, "')'");
                }
                auto id = filterId(name);
                if (id == FilterId.unknown)
                    sawUnknownFilter = true;
                e = new FilterExpr(e, id, name, args);
            }
            else if (accept(Tok.kwIs))
            {
                immutable negate = accept(Tok.kwNot);
                if (peekType != Tok.name || peek.text != "defined")
                    throw syntaxError("unknown test");
                ++ti;
                e = new DefinedExpr(e, negate);
            }
            else
                return e;
        }
    }

    Expr parseUnary()
    {
        if (accept(Tok.minus))
        {
            auto operand = parseUnary();
            if (operand.kind == ExprKind.literal)
            {
                auto lit = as!LiteralExpr(operand);
                if (lit.value.kind == Kind.integer)
                    return new LiteralExpr(Value.fromInt(-lit.value.i));
                if (lit.value.kind == Kind.floating)
                    return new LiteralExpr(Value.fromFloat(-lit.value.d));
            }
            return new UnaryExpr(ExprKind.neg, operand);
        }
        return parsePostfix();
    }

    Expr parsePostfix()
    {
        auto e = parsePrimary();
        for (;;)
        {
            if (accept(Tok.dot))
            {
                auto t = next();
                if (t.type != Tok.name && !(t.type >= Tok.kwAnd && t.type <= Tok.kwNone))
                    throw syntaxError("expected attribute name");
                string nm = t.text;
                if (nm is null)
                    nm = keywordText(t.type);
                e = new AttrExpr(e, nm);
            }
            else if (accept(Tok.lbracket))
            {
                auto idx = parseExpr();
                expect(Tok.rbracket, "']'");
                e = new IndexExpr(e, idx);
            }
            else if (accept(Tok.lparen))
            {
                e = parseCall(e);
            }
            else
                return e;
        }
    }

    Expr parseCall(Expr callee)
    {
        Expr[] args;
        string[] kwNames;
        Expr[] kwValues;
        if (peekType != Tok.rparen)
        {
            for (;;)
            {
                if (peekType == Tok.name && peekType(1) == Tok.assign)
                {
                    auto kw = next().text;
                    ++ti;
                    foreach (k; kwNames)
                        if (k == kw) throw syntaxError("duplicate keyword argument");
                    kwNames ~= kw;
                    kwValues ~= parseExpr();
                }
                else
                {
                    if (kwNames.length)
                        throw syntaxError("positional argument after keyword argument");
                    args ~= parseExpr();
                }
                if (!accept(Tok.comma)) break;
            }
        }
        expect(Tok.rparen, "')'");
        return new CallExpr(callee, args, kwNames, kwValues);
    }

    Expr parsePrimary()
    {
        auto t = next();
        switch (t.type)
        {
            case Tok.integer:  return new LiteralExpr(Value.fromInt(t.ival));
            case Tok.floating: return new LiteralExpr(Value.fromFloat(t.fval));
            case Tok.str:      return new LiteralExpr(Value.fromString(t.text));
            case Tok.kwTrue:   return new LiteralExpr(Value.fromBool(true));
            case Tok.kwFalse:  return new LiteralExpr(Value.fromBool(false));
            case Tok.kwNone:   return new LiteralExpr(Value.nil);
            case Tok.name:     return new NameExpr(t.text);
            case Tok.lbracket:
            {
                Expr[] items;
                if (peekType != Tok.rbracket)
                {
                    do items ~= parseExpr(); while (accept(Tok.comma));
                }
                expect(Tok.rbracket, "']'");
                return new ListExpr(items);
            }
            case Tok.lparen:
            {
                auto e = parseExpr();
                expect(Tok.rparen, "')'");
                return e;
            }
            default:
                throw syntaxError("unexpected token in expression");
        }
    }
}

private string keywordText(Tok t) pure nothrow @safe @nogc
{
    switch (t)
    {
        case Tok.kwAnd:   return "and";
        case Tok.kwOr:    return "or";
        case Tok.kwNot:   return "not";
        case Tok.kwIn:    return "in";
        case Tok.kwIs:    return "is";
        case Tok.kwTrue:  return "true";
        case Tok.kwFalse: return "false";
        case Tok.kwNone:  return "none";
        default:          return "";
    }
}
