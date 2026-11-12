/**
 * The template parser: items to a syntax tree.
 */
module sitegen.templating.parser;

import sitegen.templating.ast;
import sitegen.templating.errors;
import sitegen.templating.lexer;
import sitegen.templating.filters : isFilterName;

/**
 * Lexes, parses and filter-checks a template.
 *
 * Throws: `TemplateException` of kind `syntax` if the template is not
 * well formed, then of kind `filter` if it uses an unknown filter.
 */
Template parseTemplate(string name, string source)
{
    auto p = new Parser(lex(source));
    auto t = new Template;
    t.name = name;
    t.body_ = p.parseTop(t);
    foreach (f; p.filterNames)
        if (!isFilterName(f)) filterError("unknown filter " ~ f);
    return t;
}

private bool isKeyword(string s) pure nothrow @nogc @safe
{
    switch (s)
    {
        case "and", "or", "not", "in", "is", "true", "false", "none":
            return true;
        default:
            return false;
    }
}

private final class Parser
{
    Item[] items;
    size_t ip;
    Token[] toks;
    size_t tp;
    string[] filterNames;
    Template tmpl;
    int depth;
    bool sawExtends;

    this(Item[] items)
    {
        this.items = items;
    }

    Node[] parseTop(Template t)
    {
        tmpl = t;
        string end;
        auto body_ = parseBody(null, end);
        return body_;
    }

    // ------------------------------------------------------------------
    // Statements
    // ------------------------------------------------------------------

    /// Parses items until one of the `terminators` statement keywords; `end`
    /// receives the keyword, and the tokens of that tag become current.  With
    /// no terminators, parses to the end of the template.
    Node[] parseBody(const string[] terminators, out string end)
    {
        Node[] nodes;
        while (ip < items.length)
        {
            auto item = items[ip++];
            final switch (item.kind)
            {
                case ItemKind.text:
                    auto n = new Node(NodeKind.text);
                    n.text = item.text;
                    nodes ~= n;
                    break;
                case ItemKind.print:
                    {
                        toks = item.tokens;
                        tp = 0;
                        auto n = new Node(NodeKind.print);
                        n.expr = parseExpr();
                        expectEnd();
                        nodes ~= n;
                    }
                    break;
                case ItemKind.statement:
                    {
                        toks = item.tokens;
                        tp = 0;
                        if (toks.length == 0 || toks[0].kind != TokKind.name)
                            syntaxError("empty or malformed statement");
                        const kw = toks[0].text;
                        tp = 1;
                        foreach (t; terminators)
                        {
                            if (kw == t)
                            {
                                end = kw;
                                return nodes;
                            }
                        }
                        nodes ~= parseStatement(kw);
                    }
                    break;
            }
        }
        if (terminators.length) syntaxError("missing end tag");
        return nodes;
    }

    Node parseStatement(string kw)
    {
        switch (kw)
        {
            case "if": return parseIf();
            case "for": return parseFor();
            case "set": return parseSet();
            case "macro": return parseMacro();
            case "include":
                {
                    auto n = new Node(NodeKind.include);
                    n.expr = parseExpr();
                    expectEnd();
                    return n;
                }
            case "extends":
                {
                    if (depth != 0 || sawExtends) syntaxError("misplaced extends");
                    sawExtends = true;
                    auto n = new Node(NodeKind.extends);
                    n.expr = parseExpr();
                    expectEnd();
                    return n;
                }
            case "block": return parseBlock();
            default:
                syntaxError("unknown statement " ~ kw);
        }
    }

    Node parseIf()
    {
        auto n = new Node(NodeKind.if_);
        n.conds ~= parseExpr();
        expectEnd();
        depth++;
        scope (exit) depth--;
        while (true)
        {
            string end;
            auto body_ = parseBody(["elif", "else", "endif"], end);
            n.bodies ~= body_;
            if (end == "elif")
            {
                n.conds ~= parseExpr();
                expectEnd();
            }
            else if (end == "else")
            {
                expectEnd();
                string end2;
                n.elseBody = parseBody(["endif"], end2);
                expectEnd();
                break;
            }
            else
            {
                expectEnd();
                break;
            }
        }
        return n;
    }

    string expectName()
    {
        if (tp >= toks.length || toks[tp].kind != TokKind.name || isKeyword(toks[tp].text))
            syntaxError("expected a name");
        return toks[tp++].text;
    }

    Node parseFor()
    {
        auto n = new Node(NodeKind.for_);
        n.name = expectName();
        if (!isKw("in")) syntaxError("expected 'in'");
        tp++;
        n.expr = parseExpr();
        expectEnd();
        depth++;
        scope (exit) depth--;
        string end;
        n.body_ = parseBody(["else", "endfor"], end);
        if (end == "else")
        {
            expectEnd();
            string end2;
            n.elseBody = parseBody(["endfor"], end2);
        }
        expectEnd();
        return n;
    }

    Node parseSet()
    {
        auto n = new Node(NodeKind.set);
        n.name = expectName();
        if (!isOp("=")) syntaxError("expected '='");
        tp++;
        n.expr = parseExpr();
        expectEnd();
        return n;
    }

    Node parseMacro()
    {
        auto n = new Node(NodeKind.macro_);
        n.name = expectName();
        if (!isOp("(")) syntaxError("expected '('");
        tp++;
        while (!isOp(")"))
        {
            Param p;
            p.name = expectName();
            foreach (q; n.params)
                if (q.name == p.name) syntaxError("duplicate parameter");
            if (isOp("="))
            {
                tp++;
                p.defaultValue = parseExpr();
            }
            n.params ~= p;
            if (isOp(","))
                tp++;
            else if (!isOp(")"))
                syntaxError("expected ',' or ')'");
        }
        tp++;
        expectEnd();
        depth++;
        scope (exit) depth--;
        string end;
        n.body_ = parseBody(["endmacro"], end);
        expectEnd();
        return n;
    }

    Node parseBlock()
    {
        auto n = new Node(NodeKind.block);
        n.name = expectName();
        expectEnd();
        if (n.name in tmpl.blocks) syntaxError("duplicate block " ~ n.name);
        tmpl.blocks[n.name] = n;
        depth++;
        scope (exit) depth--;
        string end;
        n.body_ = parseBody(["endblock"], end);
        if (tp < toks.length)
        {
            if (expectName() != n.name) syntaxError("mismatched endblock name");
        }
        expectEnd();
        return n;
    }

    // ------------------------------------------------------------------
    // Expressions
    // ------------------------------------------------------------------

    bool isOp(string s) const
    {
        return tp < toks.length && toks[tp].kind == TokKind.op && toks[tp].text == s;
    }

    bool isKw(string s) const
    {
        return tp < toks.length && toks[tp].kind == TokKind.name && toks[tp].text == s;
    }

    void expectEnd()
    {
        if (tp != toks.length) syntaxError("unexpected tokens at the end of a tag");
    }

    void expectOp(string s)
    {
        if (!isOp(s)) syntaxError("expected '" ~ s ~ "'");
        tp++;
    }

    Expr parseExpr()
    {
        return parseOr();
    }

    Expr parseOr()
    {
        auto left = parseAnd();
        while (isKw("or"))
        {
            tp++;
            auto e = new Expr(ExprKind.or);
            e.a = left;
            e.b = parseAnd();
            left = e;
        }
        return left;
    }

    Expr parseAnd()
    {
        auto left = parseNot();
        while (isKw("and"))
        {
            tp++;
            auto e = new Expr(ExprKind.and);
            e.a = left;
            e.b = parseNot();
            left = e;
        }
        return left;
    }

    Expr parseNot()
    {
        if (isKw("not"))
        {
            tp++;
            auto e = new Expr(ExprKind.not);
            e.a = parseNot();
            return e;
        }
        return parseCompare();
    }

    Expr parseCompare()
    {
        auto first = parseAdditive();
        Expr cmp;
        while (true)
        {
            CmpOp op;
            if (isOp("=="))
                op = CmpOp.eq;
            else if (isOp("!="))
                op = CmpOp.ne;
            else if (isOp("<"))
                op = CmpOp.lt;
            else if (isOp("<="))
                op = CmpOp.le;
            else if (isOp(">"))
                op = CmpOp.gt;
            else if (isOp(">="))
                op = CmpOp.ge;
            else if (isKw("in"))
                op = CmpOp.in_;
            else if (isKw("not") && tp + 1 < toks.length && toks[tp + 1].kind == TokKind.name
                && toks[tp + 1].text == "in")
            {
                op = CmpOp.notIn;
                tp++;
            }
            else
                break;
            tp++;
            if (cmp is null)
            {
                cmp = new Expr(ExprKind.compare);
                cmp.args ~= first;
            }
            cmp.cmpOps ~= op;
            cmp.args ~= parseAdditive();
        }
        return cmp is null ? first : cmp;
    }

    Expr binary(BinOp op, Expr a, Expr b)
    {
        auto e = new Expr(ExprKind.binary);
        e.binOp = op;
        e.a = a;
        e.b = b;
        return e;
    }

    Expr parseAdditive()
    {
        auto left = parseConcat();
        while (true)
        {
            if (isOp("+"))
            {
                tp++;
                left = binary(BinOp.add, left, parseConcat());
            }
            else if (isOp("-"))
            {
                tp++;
                left = binary(BinOp.sub, left, parseConcat());
            }
            else
                break;
        }
        return left;
    }

    Expr parseConcat()
    {
        auto left = parseTerm();
        while (isOp("~"))
        {
            tp++;
            left = binary(BinOp.concat, left, parseTerm());
        }
        return left;
    }

    Expr parseTerm()
    {
        auto left = parsePower();
        while (true)
        {
            BinOp op;
            if (isOp("*"))
                op = BinOp.mul;
            else if (isOp("/"))
                op = BinOp.div;
            else if (isOp("//"))
                op = BinOp.floorDiv;
            else if (isOp("%"))
                op = BinOp.mod;
            else
                break;
            tp++;
            left = binary(op, left, parsePower());
        }
        return left;
    }

    Expr parsePower()
    {
        auto left = parseFiltered();
        while (isOp("**"))
        {
            tp++;
            left = binary(BinOp.pow, left, parseFiltered());
        }
        return left;
    }

    Expr parseFiltered()
    {
        auto e = parseUnary();
        while (true)
        {
            if (isOp("|"))
            {
                tp++;
                if (tp >= toks.length || toks[tp].kind != TokKind.name)
                    syntaxError("expected a filter name");
                auto f = new Expr(ExprKind.filter);
                f.str = toks[tp++].text;
                f.a = e;
                filterNames ~= f.str;
                if (isOp("("))
                {
                    tp++;
                    if (!isOp(")"))
                    {
                        while (true)
                        {
                            f.args ~= parseExpr();
                            if (isOp(","))
                            {
                                tp++;
                                continue;
                            }
                            break;
                        }
                    }
                    expectOp(")");
                }
                e = f;
            }
            else if (isKw("is"))
            {
                tp++;
                auto d = new Expr(ExprKind.isDefined);
                if (isKw("not"))
                {
                    tp++;
                    d.flag = true;
                }
                if (!isKw("defined")) syntaxError("unknown test");
                tp++;
                d.a = e;
                e = d;
            }
            else
                break;
        }
        return e;
    }

    Expr parseUnary()
    {
        if (isOp("-"))
        {
            tp++;
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
            if (isOp("."))
            {
                tp++;
                if (tp >= toks.length || toks[tp].kind != TokKind.name)
                    syntaxError("expected an attribute name");
                auto a = new Expr(ExprKind.attr);
                a.a = e;
                a.str = toks[tp++].text;
                e = a;
            }
            else if (isOp("["))
            {
                tp++;
                auto x = new Expr(ExprKind.index);
                x.a = e;
                x.b = parseExpr();
                expectOp("]");
                e = x;
            }
            else if (isOp("("))
            {
                tp++;
                auto c = new Expr(ExprKind.call);
                c.a = e;
                if (!isOp(")"))
                {
                    while (true)
                    {
                        if (tp + 1 < toks.length && toks[tp].kind == TokKind.name
                            && !isKeyword(toks[tp].text) && toks[tp + 1].kind == TokKind.op
                            && toks[tp + 1].text == "=")
                        {
                            const kw = toks[tp].text;
                            tp += 2;
                            foreach (k; c.kwNames)
                                if (k == kw) syntaxError("repeated keyword argument");
                            c.kwNames ~= kw;
                            c.kwValues ~= parseExpr();
                        }
                        else
                        {
                            if (c.kwNames.length) syntaxError("positional argument after keyword");
                            c.args ~= parseExpr();
                        }
                        if (isOp(","))
                        {
                            tp++;
                            continue;
                        }
                        break;
                    }
                }
                expectOp(")");
                e = c;
            }
            else
                break;
        }
        return e;
    }

    Expr parsePrimary()
    {
        if (tp >= toks.length) syntaxError("incomplete expression");
        const t = toks[tp];
        final switch (t.kind)
        {
            case TokKind.integer:
                {
                    tp++;
                    auto e = new Expr(ExprKind.intLit);
                    e.ival = t.ival;
                    return e;
                }
            case TokKind.floating:
                {
                    tp++;
                    auto e = new Expr(ExprKind.floatLit);
                    e.fval = t.fval;
                    return e;
                }
            case TokKind.string_:
                {
                    tp++;
                    auto e = new Expr(ExprKind.strLit);
                    e.str = t.text;
                    return e;
                }
            case TokKind.name:
                {
                    tp++;
                    if (t.text == "true" || t.text == "false")
                    {
                        auto e = new Expr(ExprKind.boolLit);
                        e.flag = t.text == "true";
                        return e;
                    }
                    if (t.text == "none") return new Expr(ExprKind.noneLit);
                    if (isKeyword(t.text)) syntaxError("unexpected keyword " ~ t.text);
                    auto e = new Expr(ExprKind.name);
                    e.str = t.text;
                    return e;
                }
            case TokKind.op:
                if (t.text == "(")
                {
                    tp++;
                    auto e = parseExpr();
                    expectOp(")");
                    return e;
                }
                if (t.text == "[")
                {
                    tp++;
                    auto e = new Expr(ExprKind.list);
                    if (!isOp("]"))
                    {
                        while (true)
                        {
                            e.args ~= parseExpr();
                            if (isOp(","))
                            {
                                tp++;
                                if (isOp("]")) break; // tolerate a trailing comma
                                continue;
                            }
                            break;
                        }
                    }
                    expectOp("]");
                    return e;
                }
                syntaxError("unexpected '" ~ t.text ~ "'");
        }
    }
}

unittest
{
    import std.exception : collectException;

    auto t = parseTemplate("t", "a{% if x %}b{% elif y %}c{% else %}d{% endif %}{{ z|upper }}");
    assert(t.body_.length == 3);

    foreach (bad; ["{% if x %}", "{% endif %}", "{% foo %}", "{% for a, b in x %}{% endfor %}",
            "{{ x - }}", "{{ [1, 2 }}", "{% block a %}{% endblock b %}",
            "{% block a %}{% endblock %}{% block a %}{% endblock %}",
            "{% if x %}{% extends \"b\" %}{% endif %}", "{{ x is foo }}", "{% set a, b = 1 %}",
            "{{ f(a=1, 2) }}", "{{ f(a=1, a=2) }}", "{% include \"x\" ignore missing %}"])
    {
        auto e = collectException!TemplateException(parseTemplate("t", bad));
        assert(e !is null && e.kind == ErrorKind.syntax, bad);
    }
    auto e = collectException!TemplateException(parseTemplate("t", "{{ x|nope }}"));
    assert(e !is null && e.kind == ErrorKind.filter);
}
