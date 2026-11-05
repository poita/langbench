/**
 * The KBL parser: logical lines of tokens to a statement tree.
 *
 * A file is lexed completely first (so lexical errors take precedence), then
 * parsed line by line with a block stack. Double-quoted string literals,
 * including their interpolated expressions, are parsed here too.
 */
module kiln.parser;

import kiln.ast;
import kiln.builtins : builtinId;
import kiln.errors;
import kiln.lexer;

import std.array : appender;

/// Parses the build file `src`, reporting syntax errors against `file`.
Stmt[] parseProgram(string src, string file)
{
    auto lines = lexFile(src, file);
    auto p = new ProgramParser(file);
    foreach (ref ll; lines)
        p.addLine(ll);
    return p.finish();
}

private enum Ctx : ubyte
{
    root,
    when,
    each,
    rule,
    step,
}

private final class Frame
{
    Ctx ctx;
    Stmt node;
    Stmt[] stmts;
    int headerLine;
    bool inOtherwise;

    this(Ctx c, Stmt n, int line)
    {
        ctx = c;
        node = n;
        headerLine = line;
    }
}

private final class ProgramParser
{
    string file;
    Frame[] stack;

    this(string file)
    {
        this.file = file;
        stack ~= new Frame(Ctx.root, null, 0);
    }

    void addLine(ref LogicalLine ll)
    {
        auto ex = new ExprParser(file, ll.line, ll.tokens);
        auto t = ll.tokens;
        if (t[0].isPunct("}"))
            terminator(ex, ll.line);
        else if (t[$ - 1].isPunct("{"))
            header(ex, ll.line);
        else
            simple(ex, ll.line);
    }

    Stmt[] finish()
    {
        if (stack.length > 1)
            throw parseError(file, stack[$ - 1].headerLine);
        return stack[0].stmts;
    }

    Frame top()
    {
        return stack[$ - 1];
    }

    void add(Stmt s)
    {
        top.stmts ~= s;
    }

    void terminator(ExprParser ex, int line)
    {
        auto t = ex.t;
        if (stack.length == 1)
            throw parseError(file, line);
        if (t.length == 1)
        {
            // plain close
            auto f = stack[$ - 1];
            stack.length = stack.length - 1;
            final switch (f.ctx)
            {
            case Ctx.root:
                assert(0);
            case Ctx.when:
                f.node.bodies ~= f.stmts;
                break;
            case Ctx.each:
            case Ctx.rule:
                f.node.block = f.stmts;
                break;
            case Ctx.step:
                break;
            }
            top.stmts ~= f.node;
            return;
        }
        auto f = top;
        if (f.ctx != Ctx.when || f.inOtherwise)
            throw parseError(file, line);
        if (t.length == 3 && t[1].isIdent("otherwise") && t[2].isPunct("{"))
        {
            f.node.bodies ~= f.stmts;
            f.stmts = null;
            f.inOtherwise = true;
            f.headerLine = line;
            return;
        }
        if (t.length >= 4 && t[1].isIdent("elsewhen") && t[$ - 1].isPunct("{"))
        {
            ex.pos = 2;
            ex.limit = t.length - 1;
            auto cond = ex.parseExpr();
            ex.expectEnd();
            f.node.bodies ~= f.stmts;
            f.node.conds ~= cond;
            f.stmts = null;
            f.headerLine = line;
            return;
        }
        throw parseError(file, line);
    }

    void header(ExprParser ex, int line)
    {
        auto t = ex.t;
        if (top.ctx == Ctx.step)
            throw parseError(file, line);
        ex.limit = t.length - 1;
        if (t[0].isIdent("step"))
        {
            if (t.length != 2)
                throw parseError(file, line);
            stack ~= new Frame(Ctx.step, new Stmt(SK.step, line), line);
        }
        else if (t[0].isIdent("when"))
        {
            ex.pos = 1;
            auto s = new Stmt(SK.when, line);
            s.conds ~= ex.parseExpr();
            ex.expectEnd();
            stack ~= new Frame(Ctx.when, s, line);
        }
        else if (t[0].isIdent("each"))
        {
            ex.pos = 1;
            auto s = new Stmt(SK.each, line);
            s.name = ex.plainIdent();
            if (ex.acceptPunct(","))
            {
                s.indexName = s.name;
                s.name = ex.plainIdent();
                if (s.indexName == s.name)
                    throw parseError(file, line);
            }
            if (!ex.acceptIdent("in"))
                throw parseError(file, line);
            s.expr = ex.parseExpr();
            ex.expectEnd();
            stack ~= new Frame(Ctx.each, s, line);
        }
        else if (t[0].isIdent("rule"))
        {
            ex.pos = 1;
            auto s = new Stmt(SK.rule, line);
            s.name = ex.plainIdent();
            ex.expectPunct("(");
            bool sawDefault = false;
            bool first = true;
            while (!ex.atPunct(")"))
            {
                if (!first)
                    ex.expectPunct(",");
                first = false;
                if (ex.atPunct(")"))
                    break; // trailing comma
                Param p;
                p.name = ex.plainIdent();
                foreach (ref q; s.params)
                    if (q.name == p.name)
                        throw parseError(file, line);
                if (ex.acceptPunct("="))
                {
                    p.defaultValue = ex.parseExpr();
                    sawDefault = true;
                }
                else if (sawDefault)
                    throw parseError(file, line);
                s.params ~= p;
            }
            ex.expectPunct(")");
            ex.expectEnd();
            stack ~= new Frame(Ctx.rule, s, line);
        }
        else
            throw parseError(file, line);
    }

    void simple(ExprParser ex, int line)
    {
        auto t = ex.t;
        if (t[0].kind != Tk.ident)
            throw parseError(file, line);
        immutable kw = t[0].text;
        ex.pos = 1;
        if (top.ctx == Ctx.step)
        {
            StepField f;
            switch (kw)
            {
            case "out":
                f.kind = FK.out_;
                f.expr = ex.parseExpr();
                break;
            case "in":
                f.kind = FK.in_;
                f.expr = ex.parseExpr();
                break;
            case "after":
                f.kind = FK.after;
                f.expr = ex.parseExpr();
                break;
            case "cost":
                f.kind = FK.cost;
                f.expr = ex.parseExpr();
                break;
            case "depfile":
                f.kind = FK.depfile;
                f.expr = ex.parseExpr();
                break;
            case "cmd":
                f.kind = FK.cmd;
                f.cmdName = ex.anyIdent();
                ex.expectPunct("(");
                f.cmdArgs = ex.parseArgsAfterOpen();
                break;
            default:
                throw parseError(file, line);
            }
            ex.expectEnd();
            top.node.fields ~= f;
            return;
        }
        Stmt s;
        switch (kw)
        {
        case "let":
        case "set":
            s = new Stmt(kw == "let" ? SK.let : SK.set, line);
            s.name = ex.plainIdent();
            ex.expectPunct("=");
            s.expr = ex.parseExpr();
            break;
        case "phony":
            s = new Stmt(SK.phony, line);
            s.name = ex.plainIdent();
            ex.expectPunct("=");
            s.expr = ex.parseExpr();
            break;
        case "include":
            s = new Stmt(SK.include, line);
            s.expr = ex.parseExpr();
            break;
        case "abort":
            s = new Stmt(SK.abort, line);
            s.expr = ex.parseExpr();
            break;
        case "default":
            s = new Stmt(SK.default_, line);
            s.expr = ex.parseExpr();
            break;
        case "use":
            s = new Stmt(SK.use, line);
            s.name = ex.anyIdent();
            ex.expectPunct("(");
            ex.parseUseArgs(s);
            break;
        default:
            throw parseError(file, line);
        }
        ex.expectEnd();
        add(s);
    }
}

private final class ExprParser
{
    string file;
    int line;
    Token[] t;
    size_t pos;
    size_t limit;

    this(string file, int line, Token[] tokens)
    {
        this.file = file;
        this.line = line;
        this.t = tokens;
        this.limit = tokens.length;
    }

    KilnError fail()
    {
        return parseError(file, line);
    }

    bool atEnd() const
    {
        return pos >= limit;
    }

    void expectEnd()
    {
        if (pos != limit)
            throw fail();
    }

    bool atPunct(string p) const
    {
        return pos < limit && t[pos].isPunct(p);
    }

    bool atOp(string p) const
    {
        return pos < limit && t[pos].isOp(p);
    }

    bool acceptPunct(string p)
    {
        if (atPunct(p))
        {
            pos++;
            return true;
        }
        return false;
    }

    bool acceptIdent(string p)
    {
        if (pos < limit && t[pos].isIdent(p))
        {
            pos++;
            return true;
        }
        return false;
    }

    void expectPunct(string p)
    {
        if (!acceptPunct(p))
            throw fail();
    }

    // An identifier that is not a reserved word.
    string plainIdent()
    {
        if (pos >= limit || t[pos].kind != Tk.ident || isReserved(t[pos].text))
            throw fail();
        return t[pos++].text;
    }

    // Any identifier, reserved or not (call, command and rule-use names).
    string anyIdent()
    {
        if (pos >= limit || t[pos].kind != Tk.ident)
            throw fail();
        return t[pos++].text;
    }

    // `expr {, expr} [,] )` with the opening paren already consumed.
    Expr[] parseArgsAfterOpen()
    {
        Expr[] args;
        while (!atPunct(")"))
        {
            args ~= parseExpr();
            if (!acceptPunct(","))
                break;
        }
        expectPunct(")");
        return args;
    }

    // `arg {, arg} [,] )` for `use`, with the opening paren already consumed.
    void parseUseArgs(Stmt s)
    {
        bool sawKeyword = false;
        while (!atPunct(")"))
        {
            if (pos + 1 < limit && t[pos].kind == Tk.ident && !isReserved(t[pos].text) && t[pos + 1].isPunct("="))
            {
                s.argNames ~= t[pos].text;
                pos += 2;
                sawKeyword = true;
            }
            else
            {
                if (sawKeyword)
                    throw fail();
                s.argNames ~= "";
            }
            s.args ~= parseExpr();
            if (!acceptPunct(","))
                break;
        }
        expectPunct(")");
    }

    Expr parseExpr()
    {
        return parsePipe();
    }

    Expr parsePipe()
    {
        auto e = parseOr();
        while (atOp("|>"))
        {
            pos++;
            auto name = anyIdent();
            auto c = new Expr(EK.call);
            c.text = name;
            c.fn = builtinId(name);
            c.kids ~= e;
            if (acceptPunct("("))
                c.kids ~= parseArgsAfterOpen();
            e = c;
        }
        return e;
    }

    Expr parseOr()
    {
        auto e = parseAnd();
        while (atOp("||"))
        {
            pos++;
            auto n = new Expr(EK.or);
            n.kids = [e, parseAnd()];
            e = n;
        }
        return e;
    }

    Expr parseAnd()
    {
        auto e = parseCmp();
        while (atOp("&&"))
        {
            pos++;
            auto n = new Expr(EK.and);
            n.kids = [e, parseCmp()];
            e = n;
        }
        return e;
    }

    Expr binary(BinOp op, Expr a, Expr b)
    {
        auto n = new Expr(EK.binary);
        n.op = op;
        n.kids = [a, b];
        return n;
    }

    Expr parseCmp()
    {
        auto e = parseCat();
        for (;;)
        {
            BinOp op;
            if (atOp("=="))
                op = BinOp.eq;
            else if (atOp("!="))
                op = BinOp.ne;
            else if (atOp("<"))
                op = BinOp.lt;
            else if (atOp("<="))
                op = BinOp.le;
            else if (atOp(">"))
                op = BinOp.gt;
            else if (atOp(">="))
                op = BinOp.ge;
            else
                return e;
            pos++;
            e = binary(op, e, parseCat());
        }
    }

    Expr parseCat()
    {
        auto e = parseStr();
        while (atOp("++"))
        {
            pos++;
            e = binary(BinOp.listCat, e, parseStr());
        }
        return e;
    }

    Expr parseStr()
    {
        auto e = parseAdd();
        while (atOp("~"))
        {
            pos++;
            e = binary(BinOp.strCat, e, parseAdd());
        }
        return e;
    }

    Expr parseAdd()
    {
        auto e = parseMul();
        for (;;)
        {
            if (atOp("+"))
            {
                pos++;
                e = binary(BinOp.add, e, parseMul());
            }
            else if (atOp("-"))
            {
                pos++;
                e = binary(BinOp.sub, e, parseMul());
            }
            else
                return e;
        }
    }

    Expr parseMul()
    {
        auto e = parseUnary();
        for (;;)
        {
            BinOp op;
            if (atOp("*"))
                op = BinOp.mul;
            else if (atOp("/"))
                op = BinOp.div;
            else if (atOp("%"))
                op = BinOp.mod;
            else
                return e;
            pos++;
            e = binary(op, e, parseUnary());
        }
    }

    Expr parseUnary()
    {
        if (atOp("!") || atOp("-"))
        {
            auto n = new Expr(t[pos].text == "!" ? EK.not : EK.neg);
            pos++;
            n.kids = [parseUnary()];
            return n;
        }
        return parsePostfix();
    }

    Expr parsePostfix()
    {
        auto e = parsePrimary();
        while (atPunct("["))
        {
            pos++;
            auto n = new Expr(EK.index);
            n.kids = [e, parseExpr()];
            expectPunct("]");
            e = n;
        }
        if (atPunct("("))
            throw fail(); // a call applies only to a bare identifier
        return e;
    }

    Expr parsePrimary()
    {
        if (pos >= limit)
            throw fail();
        auto tok = t[pos];
        switch (tok.kind)
        {
        case Tk.integer:
        {
            pos++;
            auto n = new Expr(EK.intLit);
            ulong v = 0;
            foreach (c; tok.text)
                v = v * 10 + (c - '0');
            n.intValue = cast(long) v;
            return n;
        }
        case Tk.str:
            pos++;
            return stringLiteral(tok);
        case Tk.ident:
        {
            pos++;
            if (atPunct("("))
            {
                pos++;
                auto n = new Expr(EK.call);
                n.text = tok.text;
                n.fn = builtinId(tok.text);
                n.kids = parseArgsAfterOpen();
                return n;
            }
            if (tok.text == "true" || tok.text == "false")
            {
                auto n = new Expr(EK.boolLit);
                n.intValue = tok.text == "true";
                return n;
            }
            if (isReserved(tok.text))
                throw fail();
            auto n = new Expr(EK.variable);
            n.text = tok.text;
            return n;
        }
        case Tk.punct:
            if (tok.text == "(")
            {
                pos++;
                auto e = parseExpr();
                expectPunct(")");
                // a parenthesised expression is never a call target
                return e;
            }
            if (tok.text == "[")
            {
                pos++;
                auto n = new Expr(EK.list);
                while (!atPunct("]"))
                {
                    n.kids ~= parseExpr();
                    if (!acceptPunct(","))
                        break;
                }
                expectPunct("]");
                return n;
            }
            throw fail();
        default:
            throw fail();
        }
    }

    Expr stringLiteral(Token tok)
    {
        string raw = tok.text;
        if (!tok.doubleQuoted)
        {
            auto n = new Expr(EK.strLit);
            auto app = appender!(char[]);
            for (size_t i = 0; i < raw.length; i++)
            {
                app.put(raw[i]);
                if (raw[i] == '\'')
                    i++; // '' is one quote
            }
            n.text = (() @trusted => cast(string) app.data)();
            return n;
        }
        InterpPart[] parts;
        auto lit = appender!(char[]);
        void flush()
        {
            if (lit.data.length)
            {
                parts ~= InterpPart((() @trusted => cast(string) lit.data.dup)(), null);
                lit.clear();
            }
        }

        size_t i = 0;
        while (i < raw.length)
        {
            immutable c = raw[i];
            if (c == '\\')
            {
                if (i + 1 >= raw.length)
                    throw fail();
                switch (raw[i + 1])
                {
                case '\\':
                    lit.put('\\');
                    break;
                case '"':
                    lit.put('"');
                    break;
                case 'n':
                    lit.put('\n');
                    break;
                case 't':
                    lit.put('\t');
                    break;
                case 'r':
                    lit.put('\r');
                    break;
                case '0':
                    lit.put('\0');
                    break;
                default:
                    throw fail();
                }
                i += 2;
            }
            else if (c == '{')
            {
                if (i + 1 < raw.length && raw[i + 1] == '{')
                {
                    lit.put('{');
                    i += 2;
                    continue;
                }
                size_t j = i + 1;
                int depth = 1;
                while (depth > 0)
                {
                    if (j >= raw.length)
                        throw fail();
                    immutable d = raw[j];
                    if (d == '"' || d == '\'')
                    {
                        immutable k = skipLiteral(raw, j);
                        if (k < 0)
                            throw fail();
                        j = k;
                    }
                    else
                    {
                        if (d == '{')
                            depth++;
                        else if (d == '}')
                            depth--;
                        j++;
                    }
                }
                string block = raw[i + 1 .. j - 1];
                Token[] bt;
                if (!tokenize(block, bt) || bt.length == 0)
                    throw fail();
                auto sub = new ExprParser(file, line, bt);
                auto e = sub.parseExpr();
                sub.expectEnd();
                flush();
                parts ~= InterpPart(null, e);
                i = j;
            }
            else if (c == '}')
            {
                if (i + 1 < raw.length && raw[i + 1] == '}')
                {
                    lit.put('}');
                    i += 2;
                }
                else
                    throw fail();
            }
            else
            {
                lit.put(c);
                i++;
            }
        }
        if (parts.length == 0)
        {
            auto n = new Expr(EK.strLit);
            n.text = (() @trusted => cast(string) lit.data.dup)();
            return n;
        }
        flush();
        auto n = new Expr(EK.interp);
        n.parts = parts;
        return n;
    }
}
