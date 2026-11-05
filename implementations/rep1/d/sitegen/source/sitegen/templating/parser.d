/// Recursive-descent parser from lexed items to a template syntax tree.
module sitegen.templating.parser;

import sitegen.templating.ast;
import sitegen.templating.errors;
import sitegen.templating.lexer;
import sitegen.templating.value;

private bool isKeyword(string n) pure nothrow @safe @nogc
{
    switch (n)
    {
    case "and": case "or": case "not": case "in": case "is":
    case "true": case "false": case "none":
        return true;
    default:
        return false;
    }
}

private FilterId filterByName(string n) pure nothrow @safe @nogc
{
    switch (n)
    {
    case "upper": return FilterId.upper;
    case "lower": return FilterId.lower;
    case "trim": return FilterId.trim;
    case "escape": return FilterId.escape;
    case "replace": return FilterId.replace;
    case "length": return FilterId.length;
    case "int": return FilterId.int_;
    case "join": return FilterId.join;
    case "first": return FilterId.first;
    case "last": return FilterId.last;
    case "reverse": return FilterId.reverse;
    case "sort": return FilterId.sort;
    case "default": return FilterId.default_;
    default: return FilterId.unknown;
    }
}

/// Parse template `source`. Throws a `syntax` error for malformed input, and
/// a `filter` error (only if the syntax is fine) for an unknown filter name.
Template parseTemplate(string name, string source)
{
    auto p = new Parser(lexTemplate(source));
    auto t = p.parseAll();
    t.name = name;
    if (p.sawUnknownFilter)
        throw new TemplateError(ErrorKind.filter);
    return t;
}

private final class Parser
{
    Item[] items;
    size_t itemPos;
    bool sawUnknownFilter;
    Stmt[] blocks;
    bool[string] blockNames;
    bool sawExtends;
    int nesting;

    // cursor over the tokens of the current tag
    Token[] toks;
    size_t tp;

    this(Item[] items)
    {
        this.items = items;
    }

    Template parseAll()
    {
        auto t = new Template;
        string end;
        t.body_ = parseBody(null, end);
        t.blocks = blocks;
        return t;
    }

    // ------------------------------------------------------------------
    // statements

    /// Parse statements until a statement tag whose keyword is in `enders`
    /// (left unconsumed; its keyword is stored in `endKeyword`) or the end.
    Stmt[] parseBody(const(string)[] enders, out string endKeyword)
    {
        Stmt[] body_;
        while (itemPos < items.length)
        {
            Item it = items[itemPos];
            final switch (it.kind)
            {
            case ItemKind.text:
            {
                ++itemPos;
                auto s = new Stmt(StmtKind.text);
                s.text = it.text;
                body_ ~= s;
                break;
            }
            case ItemKind.print:
            {
                ++itemPos;
                toks = it.tokens;
                tp = 0;
                auto s = new Stmt(StmtKind.print);
                s.expr = parseExpr();
                expectEnd();
                body_ ~= s;
                break;
            }
            case ItemKind.stmt:
            {
                toks = it.tokens;
                tp = 0;
                if (toks.length == 0 || toks[0].kind != TokKind.name)
                    throw syntaxError("empty or malformed statement");
                immutable kw = toks[0].text;
                foreach (e; enders)
                    if (e == kw)
                    {
                        endKeyword = kw;
                        return body_;
                    }
                ++itemPos;
                tp = 1;
                body_ ~= parseStatement(kw);
                break;
            }
            }
        }
        if (enders.length)
            throw syntaxError("unexpected end of template");
        return body_;
    }

    Stmt parseStatement(string kw)
    {
        switch (kw)
        {
        case "if":
            return parseIf();
        case "for":
            return parseFor();
        case "set":
        {
            auto s = new Stmt(StmtKind.set);
            s.name = expectName();
            expectOp("=");
            s.expr = parseExpr();
            expectEnd();
            return s;
        }
        case "macro":
            return parseMacro();
        case "include":
        {
            auto s = new Stmt(StmtKind.include);
            s.expr = parseExpr();
            expectEnd();
            return s;
        }
        case "extends":
        {
            if (nesting != 0 || sawExtends)
                throw syntaxError("misplaced extends");
            sawExtends = true;
            auto s = new Stmt(StmtKind.extends);
            s.expr = parseExpr();
            expectEnd();
            return s;
        }
        case "block":
            return parseBlock();
        default:
            throw syntaxError("unknown statement");
        }
    }

    Stmt parseIf()
    {
        auto s = new Stmt(StmtKind.if_);
        s.conds ~= parseExpr();
        expectEnd();
        ++nesting;
        scope (exit)
            --nesting;
        while (true)
        {
            string end;
            s.bodies ~= parseBody(["elif", "else", "endif"], end);
            ++itemPos;
            tp = 1;
            if (end == "elif")
            {
                s.conds ~= parseExpr();
                expectEnd();
            }
            else if (end == "else")
            {
                expectEnd();
                string end2;
                s.elseBody = parseBody(["endif"], end2);
                ++itemPos;
                tp = 1;
                expectEnd();
                return s;
            }
            else
            {
                expectEnd();
                return s;
            }
        }
    }

    Stmt parseFor()
    {
        auto s = new Stmt(StmtKind.for_);
        s.name = expectName();
        expectKeyword("in");
        s.expr = parseExpr();
        expectEnd();
        ++nesting;
        scope (exit)
            --nesting;
        string end;
        s.body_ = parseBody(["else", "endfor"], end);
        ++itemPos;
        tp = 1;
        expectEnd();
        if (end == "else")
        {
            string end2;
            s.elseBody = parseBody(["endfor"], end2);
            ++itemPos;
            tp = 1;
            expectEnd();
        }
        return s;
    }

    Stmt parseMacro()
    {
        auto s = new Stmt(StmtKind.macroDef);
        s.name = expectName();
        expectOp("(");
        if (!peekOp(")"))
        {
            while (true)
            {
                string pname = expectName();
                foreach (existing; s.params)
                    if (existing == pname)
                        throw syntaxError("duplicate macro parameter");
                s.params ~= pname;
                if (peekOp("="))
                {
                    ++tp;
                    s.defaults ~= parseExpr();
                }
                else
                    s.defaults ~= null;
                if (peekOp(","))
                {
                    ++tp;
                    continue;
                }
                break;
            }
        }
        expectOp(")");
        expectEnd();
        ++nesting;
        scope (exit)
            --nesting;
        string end;
        s.body_ = parseBody(["endmacro"], end);
        ++itemPos;
        tp = 1;
        expectEnd();
        return s;
    }

    Stmt parseBlock()
    {
        auto s = new Stmt(StmtKind.block);
        if (tp >= toks.length || toks[tp].kind != TokKind.name)
            throw syntaxError("block needs a name");
        s.name = toks[tp++].text;
        expectEnd();
        if (s.name in blockNames)
            throw syntaxError("duplicate block");
        blockNames[s.name] = true;
        blocks ~= s;
        ++nesting;
        scope (exit)
            --nesting;
        string end;
        s.body_ = parseBody(["endblock"], end);
        ++itemPos;
        tp = 1;
        if (tp < toks.length)
        {
            if (toks[tp].kind != TokKind.name || toks[tp].text != s.name)
                throw syntaxError("mismatched endblock name");
            ++tp;
        }
        expectEnd();
        return s;
    }

    // ------------------------------------------------------------------
    // token helpers

    bool peekOp(string op) const
    {
        return tp < toks.length && toks[tp].kind == TokKind.op && toks[tp].text == op;
    }

    bool peekName(string n) const
    {
        return tp < toks.length && toks[tp].kind == TokKind.name && toks[tp].text == n;
    }

    void expectOp(string op)
    {
        if (!peekOp(op))
            throw syntaxError("expected '" ~ op ~ "'");
        ++tp;
    }

    void expectKeyword(string kw)
    {
        if (!peekName(kw))
            throw syntaxError("expected '" ~ kw ~ "'");
        ++tp;
    }

    string expectName()
    {
        if (tp >= toks.length || toks[tp].kind != TokKind.name || isKeyword(toks[tp].text))
            throw syntaxError("expected a name");
        return toks[tp++].text;
    }

    void expectEnd()
    {
        if (tp != toks.length)
            throw syntaxError("unexpected tokens at end of tag");
    }

    // ------------------------------------------------------------------
    // expressions

    Expr parseExpr()
    {
        return parseOr();
    }

    Expr parseOr()
    {
        auto lhs = parseAnd();
        while (peekName("or"))
        {
            ++tp;
            auto e = new Expr(ExprKind.or);
            e.a = lhs;
            e.b = parseAnd();
            lhs = e;
        }
        return lhs;
    }

    Expr parseAnd()
    {
        auto lhs = parseNot();
        while (peekName("and"))
        {
            ++tp;
            auto e = new Expr(ExprKind.and);
            e.a = lhs;
            e.b = parseNot();
            lhs = e;
        }
        return lhs;
    }

    Expr parseNot()
    {
        if (peekName("not"))
        {
            ++tp;
            auto e = new Expr(ExprKind.not);
            e.a = parseNot();
            return e;
        }
        return parseCompare();
    }

    bool matchCompareOp(out CmpOp op)
    {
        if (tp >= toks.length)
            return false;
        auto t = toks[tp];
        if (t.kind == TokKind.op)
        {
            switch (t.text)
            {
            case "==": op = CmpOp.eq; break;
            case "!=": op = CmpOp.ne; break;
            case "<": op = CmpOp.lt; break;
            case "<=": op = CmpOp.le; break;
            case ">": op = CmpOp.gt; break;
            case ">=": op = CmpOp.ge; break;
            default: return false;
            }
            ++tp;
            return true;
        }
        if (t.kind == TokKind.name)
        {
            if (t.text == "in")
            {
                op = CmpOp.in_;
                ++tp;
                return true;
            }
            if (t.text == "not" && tp + 1 < toks.length && toks[tp + 1].kind == TokKind.name
                    && toks[tp + 1].text == "in")
            {
                op = CmpOp.notIn;
                tp += 2;
                return true;
            }
        }
        return false;
    }

    Expr parseCompare()
    {
        auto first = parseAdditive();
        CmpOp op;
        Expr cmp;
        while (matchCompareOp(op))
        {
            if (cmp is null)
            {
                cmp = new Expr(ExprKind.compare);
                cmp.a = first;
            }
            cmp.cmpOps ~= op;
            cmp.args ~= parseAdditive();
        }
        return cmp is null ? first : cmp;
    }

    Expr binary(Expr l, BinOp op, Expr r)
    {
        auto e = new Expr(ExprKind.binary);
        e.a = l;
        e.b = r;
        e.bop = op;
        return e;
    }

    Expr parseAdditive()
    {
        auto lhs = parseConcat();
        while (true)
        {
            if (peekOp("+"))
            {
                ++tp;
                lhs = binary(lhs, BinOp.add, parseConcat());
            }
            else if (peekOp("-"))
            {
                ++tp;
                lhs = binary(lhs, BinOp.sub, parseConcat());
            }
            else
                return lhs;
        }
    }

    Expr parseConcat()
    {
        auto lhs = parseTerm();
        while (peekOp("~"))
        {
            ++tp;
            lhs = binary(lhs, BinOp.concat, parseTerm());
        }
        return lhs;
    }

    Expr parseTerm()
    {
        auto lhs = parsePower();
        while (true)
        {
            BinOp op;
            if (peekOp("*"))
                op = BinOp.mul;
            else if (peekOp("/"))
                op = BinOp.div;
            else if (peekOp("//"))
                op = BinOp.floorDiv;
            else if (peekOp("%"))
                op = BinOp.mod;
            else
                return lhs;
            ++tp;
            lhs = binary(lhs, op, parsePower());
        }
    }

    Expr parsePower()
    {
        auto lhs = parseFiltered();
        while (peekOp("**"))
        {
            ++tp;
            lhs = binary(lhs, BinOp.pow, parseFiltered());
        }
        return lhs;
    }

    Expr parseFiltered()
    {
        auto lhs = parseUnary();
        while (true)
        {
            if (peekOp("|"))
            {
                ++tp;
                if (tp >= toks.length || toks[tp].kind != TokKind.name)
                    throw syntaxError("expected a filter name");
                auto e = new Expr(ExprKind.filter);
                e.name = toks[tp++].text;
                e.filter = filterByName(e.name);
                if (e.filter == FilterId.unknown)
                    sawUnknownFilter = true;
                e.a = lhs;
                if (peekOp("("))
                {
                    ++tp;
                    if (!peekOp(")"))
                    {
                        while (true)
                        {
                            e.args ~= parseExpr();
                            if (peekOp(","))
                            {
                                ++tp;
                                continue;
                            }
                            break;
                        }
                    }
                    expectOp(")");
                }
                lhs = e;
            }
            else if (peekName("is"))
            {
                ++tp;
                auto e = new Expr(ExprKind.isDefined);
                if (peekName("not"))
                {
                    ++tp;
                    e.negate = true;
                }
                expectKeyword("defined");
                e.a = lhs;
                lhs = e;
            }
            else
                return lhs;
        }
    }

    Expr parseUnary()
    {
        if (peekOp("-"))
        {
            ++tp;
            auto e = new Expr(ExprKind.neg);
            e.a = parseUnary();
            return e;
        }
        return parsePostfix();
    }

    Expr parsePostfix()
    {
        auto e = parsePrimary();
        while (true)
        {
            if (peekOp("."))
            {
                ++tp;
                if (tp >= toks.length || toks[tp].kind != TokKind.name)
                    throw syntaxError("expected attribute name");
                auto a = new Expr(ExprKind.attr);
                a.a = e;
                a.name = toks[tp++].text;
                a.lit = Value.of(a.name);
                e = a;
            }
            else if (peekOp("["))
            {
                ++tp;
                auto ix = new Expr(ExprKind.index);
                ix.a = e;
                ix.b = parseExpr();
                expectOp("]");
                e = ix;
            }
            else if (peekOp("("))
            {
                ++tp;
                e = parseCall(e);
            }
            else
                return e;
        }
    }

    Expr parseCall(Expr callee)
    {
        auto c = new Expr(ExprKind.call);
        c.a = callee;
        if (!peekOp(")"))
        {
            while (true)
            {
                if (tp + 1 < toks.length && toks[tp].kind == TokKind.name
                        && toks[tp + 1].kind == TokKind.op && toks[tp + 1].text == "=")
                {
                    string kw = toks[tp].text;
                    foreach (existing; c.kwNames)
                        if (existing == kw)
                            throw syntaxError("duplicate keyword argument");
                    tp += 2;
                    c.kwNames ~= kw;
                    c.kwArgs ~= parseExpr();
                }
                else
                {
                    if (c.kwNames.length)
                        throw syntaxError("positional argument after keyword argument");
                    c.args ~= parseExpr();
                }
                if (peekOp(","))
                {
                    ++tp;
                    continue;
                }
                break;
            }
        }
        expectOp(")");
        return c;
    }

    Expr parsePrimary()
    {
        if (tp >= toks.length)
            throw syntaxError("expression expected");
        Token t = toks[tp];
        switch (t.kind)
        {
        case TokKind.integer:
        {
            ++tp;
            auto e = new Expr(ExprKind.literal);
            e.lit = Value.of(t.ival);
            return e;
        }
        case TokKind.floating:
        {
            ++tp;
            auto e = new Expr(ExprKind.literal);
            e.lit = Value.of(t.fval);
            return e;
        }
        case TokKind.str:
        {
            ++tp;
            auto e = new Expr(ExprKind.literal);
            e.lit = Value.of(t.text);
            return e;
        }
        case TokKind.name:
        {
            ++tp;
            if (t.text == "true" || t.text == "false")
            {
                auto e = new Expr(ExprKind.literal);
                e.lit = Value.of(t.text == "true");
                return e;
            }
            if (t.text == "none")
            {
                auto e = new Expr(ExprKind.literal);
                e.lit = Value.none();
                return e;
            }
            if (isKeyword(t.text))
                throw syntaxError("unexpected keyword");
            auto e = new Expr(ExprKind.name);
            e.name = t.text;
            e.isRangeName = t.text == "range";
            return e;
        }
        case TokKind.op:
            if (t.text == "(")
            {
                ++tp;
                auto e = parseExpr();
                expectOp(")");
                return e;
            }
            if (t.text == "[")
            {
                ++tp;
                auto e = new Expr(ExprKind.list);
                if (!peekOp("]"))
                {
                    while (true)
                    {
                        e.args ~= parseExpr();
                        if (peekOp(","))
                        {
                            ++tp;
                            continue;
                        }
                        break;
                    }
                }
                expectOp("]");
                return e;
            }
            throw syntaxError("unexpected operator");
        default:
            throw syntaxError("unexpected token");
        }
    }
}
