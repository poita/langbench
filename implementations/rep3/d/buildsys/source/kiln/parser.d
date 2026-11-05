/// The KBL parser: logical lines to statements, and a precedence-climbing
/// expression parser (which also parses string-literal interpolations).
module kiln.parser;

import kiln.ast;
import kiln.errors;
import kiln.lexer;
import kiln.builtins : builtinIndex;

/// Parse a whole build file. Throws `E_PARSE <file>:<line>`.
Stmt[] parseFile(string src, string file)
{
    auto lines = lexFile(src, file);
    auto p = new FileParser(lines, file);
    return p.parse();
}

/// Parse a single expression from source text (used by tests and tooling).
Expr parseExpression(string text)
{
    auto toks = tokenize(text);
    auto ep = ExprParser(toks);
    auto e = ep.parseExpr();
    if (!ep.atEnd)
        throw new SyntaxFail("trailing tokens");
    return e;
}

private final class FileParser
{
    LogicalLine[] lines;
    string file;
    size_t li;

    this(LogicalLine[] lines, string file)
    {
        this.lines = lines;
        this.file = file;
    }

    Stmt[] parse()
    {
        auto body = parseBody();
        if (li < lines.length)
            throw parseError(file, lines[li].line); // stray terminator at top level
        return body;
    }

    /// Statements up to (not including) a terminator line or end of input.
    Stmt[] parseBody()
    {
        Stmt[] r;
        while (li < lines.length)
        {
            auto ll = lines[li];
            auto toks = ll.toks;
            if (toks[0].isSym("}"))
                return r;
            try
            {
                r ~= parseStatement(ll);
            }
            catch (SyntaxFail)
                throw parseError(file, ll.line);
        }
        return r;
    }

    /// Parse one simple statement or a whole block starting at lines[li].
    Stmt parseStatement(LogicalLine ll)
    {
        auto toks = ll.toks;
        if (toks[$ - 1].isSym("{"))
            return parseBlock(ll);
        ++li;
        if (toks[0].kind != TokKind.ident)
            throw new SyntaxFail();
        auto kw = toks[0].text;
        auto ep = ExprParser(toks[1 .. $]);
        Stmt s;
        switch (kw)
        {
        case "let", "set":
        {
            s = new Stmt(kw == "let" ? StmtKind.let : StmtKind.set, ll.line);
            s.name = ep.takeName();
            ep.expectSym("=");
            s.expr = ep.parseExpr();
            break;
        }
        case "phony":
        {
            s = new Stmt(StmtKind.phony, ll.line);
            s.name = ep.takeName();
            ep.expectSym("=");
            s.expr = ep.parseExpr();
            break;
        }
        case "include":
            s = new Stmt(StmtKind.include, ll.line);
            s.expr = ep.parseExpr();
            break;
        case "abort":
            s = new Stmt(StmtKind.abort, ll.line);
            s.expr = ep.parseExpr();
            break;
        case "default":
            s = new Stmt(StmtKind.def, ll.line);
            s.expr = ep.parseExpr();
            break;
        case "use":
        {
            s = new Stmt(StmtKind.use, ll.line);
            // the rule name is in its own namespace: reserved words allowed
            s.name = ep.takeAnyIdent();
            ep.expectSym("(");
            bool sawKw = false;
            while (!ep.peekSym(")"))
            {
                Arg a;
                if (ep.peekIdentNotReserved() && ep.peekSymAt(1, "="))
                {
                    a.name = ep.takeAnyIdent();
                    ep.expectSym("=");
                    sawKw = true;
                }
                else if (sawKw)
                    throw new SyntaxFail("positional after keyword");
                a.expr = ep.parseExpr();
                s.args ~= a;
                if (ep.peekSym(","))
                    ep.advance();
                else
                    break;
            }
            ep.expectSym(")");
            break;
        }
        default:
            throw new SyntaxFail("unknown statement");
        }
        if (!ep.atEnd)
            throw new SyntaxFail("trailing tokens");
        return s;
    }

    Stmt parseBlock(LogicalLine ll)
    {
        auto toks = ll.toks;
        auto head = toks[0];
        if (head.kind != TokKind.ident)
            throw new SyntaxFail();
        auto inner = toks[1 .. $ - 1];
        switch (head.text)
        {
        case "step":
            if (inner.length != 0)
                throw new SyntaxFail();
            ++li;
            return parseStep(ll);
        case "when":
            return parseWhen(ll);
        case "each":
        {
            auto s = new Stmt(StmtKind.each, ll.line);
            auto ep = ExprParser(inner);
            auto first = ep.takeName();
            if (ep.peekSym(","))
            {
                ep.advance();
                s.indexName = first;
                s.name = ep.takeName();
                if (s.indexName == s.name)
                    throw new SyntaxFail("duplicate loop variable");
            }
            else
                s.name = first;
            ep.expectIdent("in");
            s.expr = ep.parseExpr();
            if (!ep.atEnd)
                throw new SyntaxFail();
            ++li;
            s.body = parseBody();
            expectPlainClose(ll.line);
            return s;
        }
        case "rule":
        {
            auto s = new Stmt(StmtKind.rule, ll.line);
            auto ep = ExprParser(inner);
            s.name = ep.takeName();
            ep.expectSym("(");
            bool sawDefault = false;
            while (!ep.peekSym(")"))
            {
                Param p;
                p.name = ep.takeName();
                foreach (ref q; s.params)
                    if (q.name == p.name)
                        throw new SyntaxFail("duplicate parameter");
                if (ep.peekSym("="))
                {
                    ep.advance();
                    p.defaultExpr = ep.parseExpr();
                    sawDefault = true;
                }
                else if (sawDefault)
                    throw new SyntaxFail("required parameter after default");
                s.params ~= p;
                if (ep.peekSym(","))
                    ep.advance();
                else
                    break;
            }
            ep.expectSym(")");
            if (!ep.atEnd)
                throw new SyntaxFail();
            ++li;
            s.body = parseBody();
            expectPlainClose(ll.line);
            return s;
        }
        default:
            throw new SyntaxFail("bad block header");
        }
    }

    /// Consume a lone `}` closing the block opened at `headerLine`.
    void expectPlainClose(int headerLine)
    {
        if (li >= lines.length)
            throw parseError(file, headerLine);
        auto t = lines[li];
        if (t.toks.length != 1)
            throw parseError(file, t.line);
        ++li;
    }

    Stmt parseWhen(LogicalLine ll)
    {
        auto s = new Stmt(StmtKind.when, ll.line);
        int headerLine = ll.line;
        auto toks = ll.toks;
        {
            auto ep = ExprParser(toks[1 .. $ - 1]);
            Branch b;
            b.cond = ep.parseExpr();
            if (!ep.atEnd)
                throw new SyntaxFail();
            ++li;
            b.body = parseBody();
            s.branches ~= b;
        }
        bool inOtherwise = false;
        while (true)
        {
            if (li >= lines.length)
                throw parseError(file, headerLine);
            auto t = lines[li];
            auto tt = t.toks;
            if (tt.length == 1)
            {
                ++li;
                return s;
            }
            // `} elsewhen EXPR {` or `} otherwise {`
            if (inOtherwise || !tt[$ - 1].isSym("{") || tt[1].kind != TokKind.ident)
                throw parseError(file, t.line);
            if (tt[1].text == "otherwise" && tt.length == 3)
            {
                ++li;
                s.hasOtherwise = true;
                inOtherwise = true;
                headerLine = t.line;
                s.body = parseBody();
            }
            else if (tt[1].text == "elsewhen" && tt.length > 3)
            {
                Branch b;
                try
                {
                    auto ep = ExprParser(tt[2 .. $ - 1]);
                    b.cond = ep.parseExpr();
                    if (!ep.atEnd)
                        throw new SyntaxFail();
                }
                catch (SyntaxFail)
                    throw parseError(file, t.line);
                ++li;
                headerLine = t.line;
                b.body = parseBody();
                s.branches ~= b;
            }
            else
                throw parseError(file, t.line);
        }
    }

    Stmt parseStep(LogicalLine header)
    {
        auto s = new Stmt(StmtKind.step, header.line);
        while (true)
        {
            if (li >= lines.length)
                throw parseError(file, header.line);
            auto ll = lines[li];
            if (ll.toks[0].isSym("}"))
            {
                if (ll.toks.length != 1)
                    throw parseError(file, ll.line);
                ++li;
                return s;
            }
            try
            {
                s.fields ~= parseField(ll);
            }
            catch (SyntaxFail)
                throw parseError(file, ll.line);
            ++li;
        }
    }

    Field parseField(LogicalLine ll)
    {
        auto toks = ll.toks;
        if (toks[0].kind != TokKind.ident)
            throw new SyntaxFail();
        Field f;
        auto ep = ExprParser(toks[1 .. $]);
        switch (toks[0].text)
        {
        case "out":
            f.kind = FieldKind.out_;
            break;
        case "in":
            f.kind = FieldKind.in_;
            break;
        case "after":
            f.kind = FieldKind.after;
            break;
        case "cost":
            f.kind = FieldKind.cost;
            break;
        case "depfile":
            f.kind = FieldKind.depfile;
            break;
        case "cmd":
            f.kind = FieldKind.cmd;
            f.cmdName = ep.takeAnyIdent();
            ep.expectSym("(");
            f.cmdArgs = ep.parseArgList();
            if (!ep.atEnd)
                throw new SyntaxFail();
            return f;
        default:
            throw new SyntaxFail("not a step field");
        }
        f.expr = ep.parseExpr();
        if (!ep.atEnd)
            throw new SyntaxFail();
        return f;
    }
}

/// Precedence-climbing expression parser over a token slice.
struct ExprParser
{
    Token[] t;
    size_t p;

    this(Token[] toks)
    {
        t = toks;
    }

    @property bool atEnd() const
    {
        return p >= t.length;
    }

    void advance()
    {
        ++p;
    }

    bool peekSym(string s) const
    {
        return p < t.length && t[p].isSym(s);
    }

    bool peekSymAt(size_t k, string s) const
    {
        return p + k < t.length && t[p + k].isSym(s);
    }

    bool peekIdentNotReserved() const
    {
        return p < t.length && t[p].kind == TokKind.ident && !isReserved(t[p].text);
    }

    void expectSym(string s)
    {
        if (!peekSym(s))
            throw new SyntaxFail("expected " ~ s);
        ++p;
    }

    void expectIdent(string s)
    {
        if (p >= t.length || !t[p].isIdent(s))
            throw new SyntaxFail("expected " ~ s);
        ++p;
    }

    /// An identifier in a variable-like position: reserved words rejected.
    string takeName()
    {
        if (!peekIdentNotReserved())
            throw new SyntaxFail("expected name");
        return t[p++].text;
    }

    /// An identifier in a namespace of its own (call, command, rule name).
    string takeAnyIdent()
    {
        if (p >= t.length || t[p].kind != TokKind.ident)
            throw new SyntaxFail("expected identifier");
        return t[p++].text;
    }

    /// `expr { , expr } [ , ]` up to and including the closing `)`.
    Expr[] parseArgList()
    {
        Expr[] args;
        while (!peekSym(")"))
        {
            args ~= parseExpr();
            if (peekSym(","))
                ++p;
            else
                break;
        }
        expectSym(")");
        return args;
    }

    Expr parseExpr()
    {
        return parsePipe();
    }

    private Expr parsePipe()
    {
        auto lhs = parseBinary(0);
        while (peekSym("|>"))
        {
            ++p;
            auto call = new Expr(ExprKind.call);
            call.name = takeAnyIdent();
            call.fn = builtinIndex(call.name);
            call.kids = [lhs];
            if (peekSym("("))
            {
                ++p;
                call.kids ~= parseArgList();
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
        while (p < t.length && t[p].kind == TokKind.sym)
        {
            string op;
            foreach (cand; levels[level])
                if (t[p].text == cand)
                {
                    op = cand;
                    break;
                }
            if (op is null)
                break;
            ++p;
            auto rhs = parseBinary(level + 1);
            auto e = new Expr(ExprKind.binary);
            e.op = op;
            e.kids = [lhs, rhs];
            lhs = e;
        }
        return lhs;
    }

    private Expr parseUnary()
    {
        if (peekSym("!") || peekSym("-"))
        {
            auto e = new Expr(ExprKind.unary);
            e.op = t[p++].text;
            e.kids = [parseUnary()];
            return e;
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
                ++p;
                auto idx = new Expr(ExprKind.index);
                idx.kids = [e, parseExpr()];
                expectSym("]");
                e = idx;
            }
            else if (peekSym("("))
                throw new SyntaxFail("call of a non-identifier");
            else
                return e;
        }
    }

    private Expr parsePrimary()
    {
        if (p >= t.length)
            throw new SyntaxFail("unexpected end");
        auto tok = t[p];
        switch (tok.kind)
        {
        case TokKind.integer:
        {
            ++p;
            auto e = new Expr(ExprKind.intLit);
            ulong v;
            foreach (c; tok.text)
                v = v * 10 + (c - '0');
            e.num = cast(long) v;
            return e;
        }
        case TokKind.str:
            ++p;
            return parseStringLiteral(tok.text);
        case TokKind.ident:
        {
            ++p;
            if (peekSym("("))
            {
                ++p;
                auto e = new Expr(ExprKind.call);
                e.name = tok.text;
                e.fn = builtinIndex(tok.text);
                e.kids = parseArgList();
                return e;
            }
            if (tok.text == "true" || tok.text == "false")
            {
                auto e = new Expr(ExprKind.boolLit);
                e.num = tok.text == "true";
                return e;
            }
            if (isReserved(tok.text))
                throw new SyntaxFail("reserved word");
            auto e = new Expr(ExprKind.variable);
            e.name = tok.text;
            return e;
        }
        case TokKind.sym:
            if (tok.text == "(")
            {
                ++p;
                auto e = parseExpr();
                expectSym(")");
                return e;
            }
            if (tok.text == "[")
            {
                ++p;
                auto e = new Expr(ExprKind.list);
                while (!peekSym("]"))
                {
                    e.kids ~= parseExpr();
                    if (peekSym(","))
                        ++p;
                    else
                        break;
                }
                expectSym("]");
                return e;
            }
            throw new SyntaxFail("unexpected token");
        default:
            throw new SyntaxFail("unexpected token");
        }
    }
}

/// Parse the raw source of a string literal (quotes included) into a
/// `strLit` expression. Interpolation bodies are parsed here, once.
Expr parseStringLiteral(string raw)
{
    auto e = new Expr(ExprKind.strLit);
    if (raw[0] == '\'')
    {
        char[] buf;
        size_t i = 1;
        immutable end = raw.length - 1;
        while (i < end)
        {
            if (raw[i] == '\'')
            {
                buf ~= '\'';
                i += 2;
            }
            else
                buf ~= raw[i++];
        }
        e.parts = [StrPart(cast(string) buf.idup)];
        return e;
    }
    char[] lit;
    void flush()
    {
        if (lit.length)
        {
            e.parts ~= StrPart(lit.idup);
            lit.length = 0;
        }
    }
    size_t i = 1;
    immutable end = raw.length - 1;
    while (i < end)
    {
        immutable c = raw[i];
        if (c == '\\')
        {
            if (i + 1 >= end)
                throw new SyntaxFail("bad escape");
            switch (raw[i + 1])
            {
            case '\\': lit ~= '\\'; break;
            case '"': lit ~= '"'; break;
            case 'n': lit ~= '\n'; break;
            case 't': lit ~= '\t'; break;
            case 'r': lit ~= '\r'; break;
            case '0': lit ~= '\0'; break;
            default: throw new SyntaxFail("bad escape");
            }
            i += 2;
        }
        else if (c == '{')
        {
            if (i + 1 < end && raw[i + 1] == '{')
            {
                lit ~= '{';
                i += 2;
                continue;
            }
            int depth = 1;
            size_t j = i + 1;
            while (depth > 0)
            {
                if (j >= end)
                    throw new SyntaxFail("unterminated interpolation");
                immutable d = raw[j];
                if (d == '"' || d == '\'')
                    j = skipLiteral(raw, j);
                else
                {
                    if (d == '{')
                        ++depth;
                    else if (d == '}')
                        --depth;
                    ++j;
                }
            }
            auto body = raw[i + 1 .. j - 1];
            auto toks = tokenize(body);
            if (toks.length == 0)
                throw new SyntaxFail("empty interpolation");
            auto ep = ExprParser(toks);
            auto sub = ep.parseExpr();
            if (!ep.atEnd)
                throw new SyntaxFail("trailing tokens in interpolation");
            flush();
            e.parts ~= StrPart(null, sub);
            i = j;
        }
        else if (c == '}')
        {
            if (i + 1 < end && raw[i + 1] == '}')
            {
                lit ~= '}';
                i += 2;
            }
            else
                throw new SyntaxFail("lone }");
        }
        else
        {
            lit ~= c;
            ++i;
        }
    }
    flush();
    return e;
}
