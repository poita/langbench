/**
 * The KBL parser: classifies logical lines, tracks the block stack and parses
 * expressions with precedence climbing.
 */
module kiln.parser;

import kiln.ast;
import kiln.errors;
import kiln.lexer;
import kiln.value : Value;

/// Parses the build file `path` whose text is `source`.
///
/// Throws: `KilnError` of kind `E_PARSE` (detail `path:line`).
BuildFile parseBuildFile(string path, string source)
{
    import std.conv : to;

    try
    {
        auto lines = lexSource(source);
        auto bf = new BuildFile;
        bf.path = path;
        bf.statements = parseLines(lines);
        return bf;
    }
    catch (SyntaxError e)
    {
        throw new KilnError("E_PARSE", path ~ ":" ~ e.line.to!string);
    }
}

private:

enum FrameKind { root, when, each, rule, step }

final class Frame
{
    FrameKind kind;
    Stmt stmt;
    Stmt[] cur;
    bool inOtherwise;
    int headerLine;
}

Stmt[] parseLines(LogicalLine[] lines)
{
    Frame[] stack;
    auto rootFrame = new Frame;
    rootFrame.kind = FrameKind.root;
    stack ~= rootFrame;

    foreach (ref ll; lines)
    {
        try
        {
            handleLine(ll, stack);
        }
        catch (SyntaxError e)
        {
            e.line = ll.line;
            throw e;
        }
    }
    if (stack.length > 1)
        throw new SyntaxError(stack[$ - 1].headerLine, "unterminated block");
    return rootFrame.cur;
}

void closeBranch(Frame f)
{
    f.stmt.bodies ~= f.cur;
    f.cur = null;
}

void handleLine(ref LogicalLine ll, ref Frame[] stack)
{
    auto toks = ll.tokens;
    auto top = stack[$ - 1];
    if (toks[0].isSym("}"))
    {
        if (toks.length == 1)
        {
            if (stack.length == 1)
                throw new SyntaxError(ll.line);
            auto f = stack[$ - 1];
            stack = stack[0 .. $ - 1];
            auto parent = stack[$ - 1];
            final switch (f.kind)
            {
            case FrameKind.when:
                closeBranch(f);
                parent.cur ~= f.stmt;
                break;
            case FrameKind.each:
            case FrameKind.rule:
                f.stmt.body_ = f.cur;
                parent.cur ~= f.stmt;
                break;
            case FrameKind.step:
                parent.cur ~= f.stmt;
                break;
            case FrameKind.root:
                assert(false);
            }
            return;
        }
        if (top.kind != FrameKind.when || top.inOtherwise || !toks[$ - 1].isSym("{"))
            throw new SyntaxError(ll.line);
        if (toks[1].isIdent("elsewhen"))
        {
            auto p = new Parser(toks[2 .. $ - 1]);
            auto cond = p.parseExprComplete();
            closeBranch(top);
            top.stmt.conds ~= cond;
            top.headerLine = ll.line;
            return;
        }
        if (toks[1].isIdent("otherwise") && toks.length == 3)
        {
            closeBranch(top);
            top.stmt.hasOtherwise = true;
            top.inOtherwise = true;
            top.headerLine = ll.line;
            return;
        }
        throw new SyntaxError(ll.line);
    }

    if (toks[$ - 1].isSym("{"))
    {
        if (top.kind == FrameKind.step)
            throw new SyntaxError(ll.line);
        auto f = new Frame;
        f.headerLine = ll.line;
        auto s = new Stmt;
        s.line = ll.line;
        f.stmt = s;
        auto head = toks[0 .. $ - 1];
        if (head.length == 0)
            throw new SyntaxError(ll.line);
        if (head.length == 1 && head[0].isIdent("step"))
        {
            s.kind = Stmt.Kind.step;
            f.kind = FrameKind.step;
        }
        else if (head[0].isIdent("when"))
        {
            s.kind = Stmt.Kind.when;
            f.kind = FrameKind.when;
            s.conds ~= (new Parser(head[1 .. $])).parseExprComplete();
        }
        else if (head[0].isIdent("each"))
        {
            s.kind = Stmt.Kind.each;
            f.kind = FrameKind.each;
            parseEachHeader(head, s);
        }
        else if (head[0].isIdent("rule"))
        {
            s.kind = Stmt.Kind.rule;
            f.kind = FrameKind.rule;
            parseRuleHeader(head, s);
        }
        else
            throw new SyntaxError(ll.line);
        stack ~= f;
        return;
    }

    if (top.kind == FrameKind.step)
        top.stmt.fields ~= parseStepField(toks);
    else
        top.cur ~= parseSimple(ll.line, toks);
}

void parseEachHeader(Token[] head, Stmt s)
{
    // each IDENT [, IDENT] in EXPR
    size_t i = 1;
    string nameOf(size_t k)
    {
        if (k >= head.length || head[k].kind != Token.Kind.ident || isReserved(head[k].text))
            throw new SyntaxError;
        return head[k].text;
    }

    const first = nameOf(i++);
    string second = null;
    if (i < head.length && head[i].isSym(","))
    {
        ++i;
        second = nameOf(i++);
    }
    if (i >= head.length || !head[i].isIdent("in"))
        throw new SyntaxError;
    ++i;
    if (second !is null)
    {
        if (first == second)
            throw new SyntaxError;
        s.indexName = first;
        s.name = second;
    }
    else
        s.name = first;
    s.expr = (new Parser(head[i .. $])).parseExprComplete();
}

void parseRuleHeader(Token[] head, Stmt s)
{
    // rule IDENT ( [params] )
    if (head.length < 4 || head[1].kind != Token.Kind.ident || isReserved(head[1].text) || !head[2].isSym("("))
        throw new SyntaxError;
    s.name = head[1].text;
    auto p = new Parser(head[3 .. $]);
    bool sawDefault = false;
    if (p.peekSym(")"))
        p.advance();
    else
    {
        while (true)
        {
            auto t = p.next();
            if (t.kind != Token.Kind.ident || isReserved(t.text))
                throw new SyntaxError;
            foreach (ref q; s.params)
                if (q.name == t.text)
                    throw new SyntaxError;
            Param prm;
            prm.name = t.text;
            if (p.peekSym("="))
            {
                p.advance();
                prm.defaultValue = p.parseExpr();
                sawDefault = true;
            }
            else if (sawDefault)
                throw new SyntaxError;
            s.params ~= prm;
            if (p.peekSym(","))
            {
                p.advance();
                if (p.peekSym(")"))
                {
                    p.advance();
                    break;
                }
                continue;
            }
            p.expectSym(")");
            break;
        }
    }
    p.expectEnd();
}

Stmt parseSimple(int line, Token[] toks)
{
    auto s = new Stmt;
    s.line = line;
    if (toks[0].kind != Token.Kind.ident)
        throw new SyntaxError;
    auto p = new Parser(toks[1 .. $]);

    string bindName()
    {
        auto t = p.next();
        if (t.kind != Token.Kind.ident || isReserved(t.text))
            throw new SyntaxError;
        return t.text;
    }

    switch (toks[0].text)
    {
    case "let":
    case "set":
    case "phony":
        s.kind = toks[0].text == "let" ? Stmt.Kind.let : (toks[0].text == "set" ? Stmt.Kind.set : Stmt.Kind.phony);
        s.name = bindName();
        p.expectSym("=");
        s.expr = p.parseExprComplete();
        break;
    case "include":
        s.kind = Stmt.Kind.include;
        s.expr = p.parseExprComplete();
        break;
    case "abort":
        s.kind = Stmt.Kind.abort;
        s.expr = p.parseExprComplete();
        break;
    case "default":
        s.kind = Stmt.Kind.default_;
        s.expr = p.parseExprComplete();
        break;
    case "use":
        s.kind = Stmt.Kind.use;
        auto t = p.next();
        if (t.kind != Token.Kind.ident)
            throw new SyntaxError;
        s.name = t.text;
        p.expectSym("(");
        s.useArgs = p.parseUseArgs();
        p.expectEnd();
        break;
    default:
        throw new SyntaxError;
    }
    return s;
}

StepField parseStepField(Token[] toks)
{
    StepField f;
    if (toks[0].kind != Token.Kind.ident)
        throw new SyntaxError;
    auto p = new Parser(toks[1 .. $]);
    switch (toks[0].text)
    {
    case "out": f.kind = StepField.Kind.out_; break;
    case "in": f.kind = StepField.Kind.in_; break;
    case "after": f.kind = StepField.Kind.after; break;
    case "cost": f.kind = StepField.Kind.cost; break;
    case "depfile": f.kind = StepField.Kind.depfile; break;
    case "cmd":
        f.kind = StepField.Kind.cmd;
        auto t = p.next();
        if (t.kind != Token.Kind.ident)
            throw new SyntaxError;
        f.cmdName = t.text;
        p.expectSym("(");
        f.cmdArgs = p.parseExprList(")");
        p.expectEnd();
        return f;
    default:
        throw new SyntaxError;
    }
    f.expr = p.parseExprComplete();
    return f;
}

/// Recursive-descent expression parser over one token slice.
final class Parser
{
    private Token[] t;
    private size_t pos;

    this(Token[] tokens) { t = tokens; }

    bool atEnd() const { return pos >= t.length; }

    Token next()
    {
        if (pos >= t.length)
            throw new SyntaxError;
        return t[pos++];
    }

    void advance() { ++pos; }

    bool peekSym(string s) const { return pos < t.length && t[pos].isSym(s); }

    void expectSym(string s)
    {
        if (!peekSym(s))
            throw new SyntaxError;
        ++pos;
    }

    void expectEnd()
    {
        if (pos != t.length)
            throw new SyntaxError;
    }

    Expr parseExprComplete()
    {
        auto e = parseExpr();
        expectEnd();
        return e;
    }

    Expr parseExpr() { return parsePipe(); }

    /// Parses `expr {, expr} [,]` up to and including the closing symbol `close`.
    Expr[] parseExprList(string close)
    {
        Expr[] r;
        if (peekSym(close))
        {
            ++pos;
            return r;
        }
        while (true)
        {
            r ~= parseExpr();
            if (peekSym(","))
            {
                ++pos;
                if (peekSym(close))
                {
                    ++pos;
                    return r;
                }
                continue;
            }
            expectSym(close);
            return r;
        }
    }

    /// Parses the arguments of a `use` statement up to and including `)`.
    UseArg[] parseUseArgs()
    {
        UseArg[] r;
        bool sawKeyword = false;
        if (peekSym(")"))
        {
            ++pos;
            return r;
        }
        while (true)
        {
            UseArg a;
            if (pos + 1 < t.length && t[pos].kind == Token.Kind.ident && !isReserved(t[pos].text)
                && t[pos + 1].isSym("="))
            {
                a.keyword = t[pos].text;
                pos += 2;
                sawKeyword = true;
            }
            else if (sawKeyword)
                throw new SyntaxError;
            a.value = parseExpr();
            r ~= a;
            if (peekSym(","))
            {
                ++pos;
                if (peekSym(")"))
                {
                    ++pos;
                    return r;
                }
                continue;
            }
            expectSym(")");
            return r;
        }
    }

    private Expr parsePipe()
    {
        auto lhs = parseBinary(0);
        while (peekSym("|>"))
        {
            ++pos;
            auto name = next();
            if (name.kind != Token.Kind.ident)
                throw new SyntaxError;
            auto call = new Expr;
            call.kind = Expr.Kind.call;
            call.name = name.text;
            call.args = [lhs];
            if (peekSym("("))
            {
                ++pos;
                call.args ~= parseExprList(")");
            }
            lhs = call;
        }
        return lhs;
    }

    private static immutable string[][] levels = [
        ["||"], ["&&"], ["==", "!=", "<", "<=", ">", ">="], ["++"], ["~"], ["+", "-"], ["*", "/", "%"],
    ];

    private Expr parseBinary(size_t level)
    {
        if (level == levels.length)
            return parseUnary();
        auto lhs = parseBinary(level + 1);
        while (pos < t.length && t[pos].kind == Token.Kind.symbol && isOpAt(level, t[pos].text))
        {
            const op = t[pos++].text;
            auto rhs = parseBinary(level + 1);
            auto b = new Expr;
            b.kind = Expr.Kind.binary;
            b.name = op;
            b.args = [lhs, rhs];
            lhs = b;
        }
        return lhs;
    }

    private static bool isOpAt(size_t level, string s)
    {
        foreach (o; levels[level])
            if (o == s)
                return true;
        return false;
    }

    private Expr parseUnary()
    {
        if (peekSym("!") || peekSym("-"))
        {
            const op = t[pos++].text;
            auto u = new Expr;
            u.kind = Expr.Kind.unary;
            u.name = op;
            u.args = [parseUnary()];
            return u;
        }
        return parsePostfix();
    }

    private Expr parsePostfix()
    {
        auto e = parsePrimary();
        while (true)
        {
            if (peekSym("["))
            {
                ++pos;
                auto i = parseExpr();
                expectSym("]");
                auto x = new Expr;
                x.kind = Expr.Kind.index;
                x.args = [e, i];
                e = x;
            }
            else if (peekSym("("))
                throw new SyntaxError; // a call applies only to an identifier
            else
                return e;
        }
    }

    private Expr parsePrimary()
    {
        auto tok = next();
        auto e = new Expr;
        final switch (tok.kind)
        {
        case Token.Kind.integer:
            e.kind = Expr.Kind.literal;
            ulong v = 0;
            foreach (char c; tok.text)
                v = v * 10 + (c - '0');
            e.lit = Value.ofInt(cast(long) v);
            return e;
        case Token.Kind.str:
            return parseStringLiteral(tok.text);
        case Token.Kind.ident:
            if (peekSym("("))
            {
                ++pos;
                e.kind = Expr.Kind.call;
                e.name = tok.text;
                e.args = parseExprList(")");
                return e;
            }
            if (tok.text == "true" || tok.text == "false")
            {
                e.kind = Expr.Kind.literal;
                e.lit = Value.ofBool(tok.text == "true");
                return e;
            }
            if (isReserved(tok.text))
                throw new SyntaxError;
            e.kind = Expr.Kind.variable;
            e.name = tok.text;
            return e;
        case Token.Kind.symbol:
            if (tok.text == "(")
            {
                auto inner = parseExpr();
                expectSym(")");
                return inner;
            }
            if (tok.text == "[")
            {
                e.kind = Expr.Kind.list;
                e.args = parseExprList("]");
                return e;
            }
            throw new SyntaxError;
        }
    }
}

/// Parses a string-literal token (quotes included) into a literal or interpolation node.
Expr parseStringLiteral(string raw)
{
    auto e = new Expr;
    const content = raw[1 .. $ - 1];
    if (raw[0] == '\'')
    {
        char[] buf;
        size_t i = 0;
        while (i < content.length)
        {
            buf ~= content[i];
            i += (content[i] == '\'') ? 2 : 1;
        }
        e.kind = Expr.Kind.literal;
        e.lit = Value.ofStr(buf.idup);
        return e;
    }

    Expr.Part[] parts;
    char[] lit;
    void flush()
    {
        if (lit.length)
        {
            parts ~= Expr.Part(lit.idup, null);
            lit = null;
        }
    }

    size_t i = 0;
    while (i < content.length)
    {
        const c = content[i];
        if (c == '\\')
        {
            if (i + 1 >= content.length)
                throw new SyntaxError;
            switch (content[i + 1])
            {
            case '\\': lit ~= '\\'; break;
            case '"': lit ~= '"'; break;
            case 'n': lit ~= '\n'; break;
            case 't': lit ~= '\t'; break;
            case 'r': lit ~= '\r'; break;
            case '0': lit ~= '\0'; break;
            default: throw new SyntaxError;
            }
            i += 2;
        }
        else if (c == '{')
        {
            if (i + 1 < content.length && content[i + 1] == '{')
            {
                lit ~= '{';
                i += 2;
            }
            else
            {
                const end = skipRegion(content, i + 1);
                const body_ = content[i + 1 .. end - 1];
                auto toks = tokenize(body_);
                if (toks.length == 0)
                    throw new SyntaxError;
                flush();
                parts ~= Expr.Part(null, (new Parser(toks)).parseExprComplete());
                i = end;
            }
        }
        else if (c == '}')
        {
            if (i + 1 < content.length && content[i + 1] == '}')
            {
                lit ~= '}';
                i += 2;
            }
            else
                throw new SyntaxError;
        }
        else
        {
            lit ~= c;
            ++i;
        }
    }
    flush();
    bool constant = true;
    foreach (ref p; parts)
        if (p.expr !is null)
            constant = false;
    if (constant)
    {
        e.kind = Expr.Kind.literal;
        e.lit = Value.ofStr(parts.length ? parts[0].literal : "");
        // Adjacent literal parts are merged by `flush`, so at most one exists.
    }
    else
    {
        e.kind = Expr.Kind.interp;
        e.parts = parts;
    }
    return e;
}

unittest
{
    auto bf = parseBuildFile("main.kiln", "let x = 1 + 2 * 3\nlet s = \"a{x}b{{c}}\"\n");
    assert(bf.statements.length == 2);
    assert(bf.statements[0].kind == Stmt.Kind.let && bf.statements[0].expr.name == "+");
    assert(bf.statements[1].expr.kind == Expr.Kind.interp && bf.statements[1].expr.parts.length == 3);
}

unittest
{
    string errAt(string src)
    {
        try
        {
            parseBuildFile("f", src);
            return "ok";
        }
        catch (KilnError e)
            return e.detail;
    }

    assert(errAt("let = 1\nlet x = \"abc\n") == "f:2"); // lexical errors come first
    assert(errAt("let x = 1 2\n") == "f:1");
    assert(errAt("out \"x\"\n") == "f:1");
    assert(errAt("step {\n let x = 1\n}\n") == "f:2");
    assert(errAt("when true {\n") == "f:1");
    assert(errAt("when true {\n} otherwise {\nlet x = 1\n") == "f:2");
    assert(errAt("}\n") == "f:1");
    assert(errAt("each a, a in [] {\n}\n") == "f:1");
    assert(errAt("rule r(a = 1, b) {\n}\n") == "f:1");
    assert(errAt("rule r(a, a) {\n}\n") == "f:1");
    assert(errAt("use r(a = 1, 2)\n") == "f:1");
    assert(errAt("let x = f(1)(2)\n") == "f:1");
    assert(errAt("let x = \"{}\"\n") == "f:1");
    assert(errAt("let x = \"a}b\"\n") == "f:1");
    assert(errAt("let x = \"\\q\"\n") == "f:1");
    assert(errAt("let x = let\n") == "f:1");
    assert(errAt("let x = 1 |> cost\n") == "ok");
    assert(errAt("use cost()\nlet y = true(1)\n") == "ok");
    assert(errAt("when true {\n} elsewhen false {\n} otherwise {\n} elsewhen true {\n}\n") == "f:4");
    assert(errAt("{\n") == "f:1");
}
