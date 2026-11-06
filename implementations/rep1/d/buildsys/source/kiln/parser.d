/// KBL parser: logical lines -> statements and expressions.
module kiln.parser;

import kiln.ast;
import kiln.errors;
import kiln.lexer;

/// Parses the build file `text` (named `file` in error messages) into statements.
///
/// Throws `KilnError` (`E_PARSE`) with the line of the first offending logical
/// line, or of the innermost unterminated block.
Stmt[] parseSource(string file, string text) @safe
{
    auto p = new Parser(file, lexSource(file, text));
    return p.parseFile();
}

private final class Parser
{
    string file;
    LogicalLine[] lines;
    size_t pos;
    int curLine;
    Token[] toks;
    size_t tp, tend;

    this(string file, LogicalLine[] lines) @safe
    {
        this.file = file;
        this.lines = lines;
    }

    KilnError fail() @safe
    {
        return parseError(file, curLine);
    }

    // ---------------------------------------------------------------- blocks

    Stmt[] parseFile() @safe
    {
        auto stmts = parseBody(0, false);
        return stmts;
    }

    private bool isSymTok(size_t i, string s) const @safe
    {
        return toks[i].kind == TokKind.sym && toks[i].text == s;
    }

    private bool isIdentTok(size_t i, string s) const @safe
    {
        return toks[i].kind == TokKind.ident && toks[i].text == s;
    }

    /// Parses statements until a terminator line (left unconsumed) or end of file.
    Stmt[] parseBody(int headerLine, bool nested) @safe
    {
        Stmt[] result;
        while (pos < lines.length)
        {
            auto ln = &lines[pos];
            curLine = ln.line;
            toks = ln.tokens;
            tp = 0;
            tend = toks.length;
            if (isSymTok(0, "}"))
            {
                if (!nested)
                    throw fail();
                return result;
            }
            if (isSymTok(tend - 1, "{"))
            {
                result ~= parseHeader();
                continue;
            }
            result ~= parseSimple();
            ++pos;
        }
        if (nested)
            throw parseError(file, headerLine);
        return result;
    }

    /// At a terminator line: require exactly `}` and consume it.
    private void closeBlock() @safe
    {
        auto ln = &lines[pos];
        curLine = ln.line;
        if (ln.tokens.length != 1)
            throw fail();
        ++pos;
    }

    private Stmt parseHeader() @safe
    {
        const line = curLine;
        tend = toks.length - 1; // exclude the trailing '{'
        if (tend == 0 || toks[0].kind != TokKind.ident)
            throw fail();
        switch (toks[0].text)
        {
        case "step":
            if (tend != 1)
                throw fail();
            return parseStepBlock(line);
        case "when":
            return parseWhen(line);
        case "each":
            return parseEach(line);
        case "rule":
            return parseRule(line);
        default:
            throw fail();
        }
    }

    private Stmt parseWhen(int line) @safe
    {
        auto s = new Stmt;
        s.kind = StmtKind.when;
        s.line = line;
        tp = 1;
        auto cond = parseExpr();
        if (tp != tend)
            throw fail();
        ++pos;
        int headerLine = line;
        while (true)
        {
            auto body_ = parseBody(headerLine, true);
            s.conds ~= cond;
            s.bodies ~= body_;
            // at a terminator
            auto ln = &lines[pos];
            curLine = ln.line;
            toks = ln.tokens;
            if (toks.length == 1)
            {
                ++pos;
                return s;
            }
            if (isIdentTok(1, "elsewhen") && isSymTok(toks.length - 1, "{") && toks.length >= 4)
            {
                tp = 2;
                tend = toks.length - 1;
                cond = parseExpr();
                if (tp != tend)
                    throw fail();
                headerLine = curLine;
                ++pos;
                continue;
            }
            if (isIdentTok(1, "otherwise") && toks.length == 3 && isSymTok(2, "{"))
            {
                headerLine = curLine;
                ++pos;
                s.otherwise = parseBody(headerLine, true);
                s.hasOtherwise = true;
                closeBlock();
                return s;
            }
            throw fail();
        }
    }

    private Stmt parseEach(int line) @safe
    {
        auto s = new Stmt;
        s.kind = StmtKind.each;
        s.line = line;
        tp = 1;
        string n1 = expectName();
        string n2;
        if (tp < tend && isSymTok(tp, ","))
        {
            ++tp;
            n2 = expectName();
            if (n1 == n2)
                throw fail();
            s.indexName = n1;
            s.name = n2;
        }
        else
            s.name = n1;
        if (tp >= tend || !isIdentTok(tp, "in"))
            throw fail();
        ++tp;
        s.expr = parseExpr();
        if (tp != tend)
            throw fail();
        ++pos;
        s.body = parseBody(line, true);
        closeBlock();
        return s;
    }

    private Stmt parseRule(int line) @safe
    {
        auto s = new Stmt;
        s.kind = StmtKind.rule;
        s.line = line;
        tp = 1;
        s.name = expectName();
        if (tp >= tend || !isSymTok(tp, "("))
            throw fail();
        ++tp;
        bool sawDefault = false;
        if (tp < tend && isSymTok(tp, ")"))
        {
            ++tp;
        }
        else
        {
            while (true)
            {
                Param prm;
                prm.name = expectName();
                foreach (ref q; s.params)
                    if (q.name == prm.name)
                        throw fail();
                if (tp < tend && isSymTok(tp, "="))
                {
                    ++tp;
                    prm.def = parseExpr();
                    sawDefault = true;
                }
                else if (sawDefault)
                    throw fail();
                s.params ~= prm;
                if (tp < tend && isSymTok(tp, ","))
                {
                    ++tp;
                    if (tp < tend && isSymTok(tp, ")"))
                    {
                        ++tp;
                        break;
                    }
                    continue;
                }
                if (tp < tend && isSymTok(tp, ")"))
                {
                    ++tp;
                    break;
                }
                throw fail();
            }
        }
        if (tp != tend)
            throw fail();
        ++pos;
        s.body = parseBody(line, true);
        closeBlock();
        return s;
    }

    private Stmt parseStepBlock(int line) @safe
    {
        auto s = new Stmt;
        s.kind = StmtKind.step;
        s.line = line;
        ++pos;
        while (true)
        {
            if (pos >= lines.length)
                throw parseError(file, line);
            auto ln = &lines[pos];
            curLine = ln.line;
            toks = ln.tokens;
            tp = 0;
            tend = toks.length;
            if (isSymTok(0, "}"))
            {
                closeBlock();
                return s;
            }
            if (isSymTok(tend - 1, "{"))
                throw fail();
            s.fields ~= parseField();
            ++pos;
        }
    }

    private StepField parseField() @safe
    {
        StepField f;
        if (toks[0].kind != TokKind.ident)
            throw fail();
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
            break;
        default:
            throw fail();
        }
        tp = 1;
        if (f.kind == FieldKind.cmd)
        {
            if (tp >= tend || toks[tp].kind != TokKind.ident)
                throw fail();
            f.cmdName = toks[tp].text;
            ++tp;
            if (tp >= tend || !isSymTok(tp, "("))
                throw fail();
            ++tp;
            f.args = parseArgList();
        }
        else
            f.expr = parseExpr();
        if (tp != tend)
            throw fail();
        return f;
    }

    // ------------------------------------------------------ simple statements

    private string expectName() @safe
    {
        if (tp >= tend || toks[tp].kind != TokKind.ident || isReserved(toks[tp].text))
            throw fail();
        return toks[tp++].text;
    }

    private Stmt parseSimple() @safe
    {
        auto s = new Stmt;
        s.line = curLine;
        if (toks[0].kind != TokKind.ident)
            throw fail();
        tp = 1;
        switch (toks[0].text)
        {
        case "let":
        case "set":
            s.kind = toks[0].text == "let" ? StmtKind.let : StmtKind.set;
            s.name = expectName();
            if (tp >= tend || !isSymTok(tp, "="))
                throw fail();
            ++tp;
            s.expr = parseExpr();
            break;
        case "phony":
            s.kind = StmtKind.phony;
            s.name = expectName();
            if (tp >= tend || !isSymTok(tp, "="))
                throw fail();
            ++tp;
            s.expr = parseExpr();
            break;
        case "include":
            s.kind = StmtKind.include;
            s.expr = parseExpr();
            break;
        case "abort":
            s.kind = StmtKind.abort;
            s.expr = parseExpr();
            break;
        case "default":
            s.kind = StmtKind.default_;
            s.expr = parseExpr();
            break;
        case "use":
            s.kind = StmtKind.use;
            if (tp >= tend || toks[tp].kind != TokKind.ident)
                throw fail();
            s.name = toks[tp++].text;
            if (tp >= tend || !isSymTok(tp, "("))
                throw fail();
            ++tp;
            parseUseArgs(s);
            break;
        default:
            throw fail();
        }
        if (tp != tend)
            throw fail();
        return s;
    }

    private void parseUseArgs(Stmt s) @safe
    {
        if (tp < tend && isSymTok(tp, ")"))
        {
            ++tp;
            return;
        }
        while (true)
        {
            if (tp + 1 < tend && toks[tp].kind == TokKind.ident && !isReserved(toks[tp].text)
                    && isSymTok(tp + 1, "="))
            {
                KwArg kw;
                kw.name = toks[tp].text;
                tp += 2;
                kw.value = parseExpr();
                s.kwArgs ~= kw;
            }
            else
            {
                if (s.kwArgs.length)
                    throw fail();
                s.posArgs ~= parseExpr();
            }
            if (tp < tend && isSymTok(tp, ","))
            {
                ++tp;
                if (tp < tend && isSymTok(tp, ")"))
                {
                    ++tp;
                    return;
                }
                continue;
            }
            if (tp < tend && isSymTok(tp, ")"))
            {
                ++tp;
                return;
            }
            throw fail();
        }
    }

    // ------------------------------------------------------------ expressions

    /// Parses `[expr {, expr} [,]] )` after the opening parenthesis has been consumed.
    private Expr[] parseArgList() @safe
    {
        Expr[] args;
        if (tp < tend && isSymTok(tp, ")"))
        {
            ++tp;
            return args;
        }
        while (true)
        {
            args ~= parseExpr();
            if (tp < tend && isSymTok(tp, ","))
            {
                ++tp;
                if (tp < tend && isSymTok(tp, ")"))
                {
                    ++tp;
                    return args;
                }
                continue;
            }
            if (tp < tend && isSymTok(tp, ")"))
            {
                ++tp;
                return args;
            }
            throw fail();
        }
    }

    private bool atSym(string s) const @safe
    {
        return tp < tend && toks[tp].kind == TokKind.sym && toks[tp].text == s;
    }

    Expr parseExpr() @safe
    {
        auto e = parseOr();
        while (atSym("|>"))
        {
            ++tp;
            if (tp >= tend || toks[tp].kind != TokKind.ident)
                throw fail();
            auto c = new Expr;
            c.kind = ExprKind.call;
            c.name = toks[tp++].text;
            c.kids = [e];
            if (atSym("("))
            {
                ++tp;
                c.kids ~= parseArgList();
            }
            e = c;
        }
        return e;
    }

    private Expr parseOr() @safe
    {
        auto e = parseAnd();
        while (atSym("||"))
        {
            ++tp;
            auto r = parseAnd();
            e = binary(ExprKind.logicalOr, Op.add, e, r);
        }
        return e;
    }

    private Expr parseAnd() @safe
    {
        auto e = parseCmp();
        while (atSym("&&"))
        {
            ++tp;
            auto r = parseCmp();
            e = binary(ExprKind.logicalAnd, Op.add, e, r);
        }
        return e;
    }

    private static Expr binary(ExprKind k, Op op, Expr l, Expr r) @safe
    {
        auto e = new Expr;
        e.kind = k;
        e.op = op;
        e.kids = [l, r];
        return e;
    }

    private Expr parseCmp() @safe
    {
        auto e = parseCat();
        while (tp < tend && toks[tp].kind == TokKind.sym)
        {
            Op op;
            switch (toks[tp].text)
            {
            case "==":
                op = Op.eq;
                break;
            case "!=":
                op = Op.ne;
                break;
            case "<":
                op = Op.lt;
                break;
            case "<=":
                op = Op.le;
                break;
            case ">":
                op = Op.gt;
                break;
            case ">=":
                op = Op.ge;
                break;
            default:
                return e;
            }
            ++tp;
            e = binary(ExprKind.binary, op, e, parseCat());
        }
        return e;
    }

    private Expr parseCat() @safe
    {
        auto e = parseStr();
        while (atSym("++"))
        {
            ++tp;
            e = binary(ExprKind.binary, Op.concatList, e, parseStr());
        }
        return e;
    }

    private Expr parseStr() @safe
    {
        auto e = parseAdd();
        while (atSym("~"))
        {
            ++tp;
            e = binary(ExprKind.binary, Op.concatStr, e, parseAdd());
        }
        return e;
    }

    private Expr parseAdd() @safe
    {
        auto e = parseMul();
        while (atSym("+") || atSym("-"))
        {
            const op = toks[tp].text == "+" ? Op.add : Op.sub;
            ++tp;
            e = binary(ExprKind.binary, op, e, parseMul());
        }
        return e;
    }

    private Expr parseMul() @safe
    {
        auto e = parseUnary();
        while (atSym("*") || atSym("/") || atSym("%"))
        {
            const t = toks[tp].text;
            const op = t == "*" ? Op.mul : (t == "/" ? Op.div : Op.mod);
            ++tp;
            e = binary(ExprKind.binary, op, e, parseUnary());
        }
        return e;
    }

    private Expr parseUnary() @safe
    {
        if (atSym("!") || atSym("-"))
        {
            auto e = new Expr;
            e.kind = ExprKind.unary;
            e.op = toks[tp].text == "!" ? Op.not : Op.neg;
            ++tp;
            e.kids = [parseUnary()];
            return e;
        }
        return parsePostfix();
    }

    private Expr parsePostfix() @safe
    {
        auto e = parsePrimary();
        while (true)
        {
            if (atSym("["))
            {
                ++tp;
                auto idx = parseExpr();
                if (!atSym("]"))
                    throw fail();
                ++tp;
                auto n = new Expr;
                n.kind = ExprKind.index;
                n.kids = [e, idx];
                e = n;
            }
            else if (atSym("("))
                throw fail(); // calls apply only to bare identifiers
            else
                return e;
        }
    }

    private Expr parsePrimary() @safe
    {
        if (tp >= tend)
            throw fail();
        const t = toks[tp];
        auto e = new Expr;
        switch (t.kind)
        {
        case TokKind.integer:
            ++tp;
            e.kind = ExprKind.intLit;
            e.ival = t.value;
            return e;
        case TokKind.str:
            ++tp;
            return parseStringLiteral(t);
        case TokKind.ident:
            ++tp;
            if (atSym("("))
            {
                ++tp;
                e.kind = ExprKind.call;
                e.name = t.text;
                e.kids = parseArgList();
                return e;
            }
            if (t.text == "true" || t.text == "false")
            {
                e.kind = ExprKind.boolLit;
                e.ival = t.text == "true";
                return e;
            }
            if (isReserved(t.text))
                throw fail();
            e.kind = ExprKind.variable;
            e.name = t.text;
            return e;
        case TokKind.sym:
            if (t.text == "(")
            {
                ++tp;
                auto inner = parseExpr();
                if (!atSym(")"))
                    throw fail();
                ++tp;
                return inner;
            }
            if (t.text == "[")
            {
                ++tp;
                e.kind = ExprKind.list;
                if (atSym("]"))
                {
                    ++tp;
                    return e;
                }
                while (true)
                {
                    e.kids ~= parseExpr();
                    if (atSym(","))
                    {
                        ++tp;
                        if (atSym("]"))
                        {
                            ++tp;
                            return e;
                        }
                        continue;
                    }
                    if (atSym("]"))
                    {
                        ++tp;
                        return e;
                    }
                    throw fail();
                }
            }
            throw fail();
        default:
            throw fail();
        }
    }

    // --------------------------------------------------------- string literals

    private Expr parseStringLiteral(const Token t) @safe
    {
        auto e = new Expr;
        const body_ = t.text;
        if (!t.dq)
        {
            char[] buf;
            buf.reserve(body_.length);
            size_t i = 0;
            while (i < body_.length)
            {
                buf ~= body_[i];
                i += (body_[i] == '\'' && i + 1 < body_.length && body_[i + 1] == '\'') ? 2 : 1;
            }
            e.kind = ExprKind.strLit;
            e.name = (() @trusted => cast(string) buf)();
            return e;
        }
        char[] buf;
        StrPart[] parts;
        size_t i = 0;
        const n = body_.length;
        while (i < n)
        {
            const c = body_[i];
            if (c == '\\')
            {
                if (i + 1 >= n)
                    throw fail();
                switch (body_[i + 1])
                {
                case '\\':
                    buf ~= '\\';
                    break;
                case '"':
                    buf ~= '"';
                    break;
                case 'n':
                    buf ~= '\n';
                    break;
                case 't':
                    buf ~= '\t';
                    break;
                case 'r':
                    buf ~= '\r';
                    break;
                case '0':
                    buf ~= '\0';
                    break;
                default:
                    throw fail();
                }
                i += 2;
            }
            else if (c == '{')
            {
                if (i + 1 < n && body_[i + 1] == '{')
                {
                    buf ~= '{';
                    i += 2;
                    continue;
                }
                const end = scanRegion(body_, i + 1);
                if (end < 0)
                    throw fail();
                const inner = body_[i + 1 .. cast(size_t) end - 1];
                Token[] sub;
                if (!tokenize(inner, sub) || sub.length == 0)
                    throw fail();
                auto saveToks = toks;
                const saveTp = tp, saveEnd = tend;
                toks = sub;
                tp = 0;
                tend = sub.length;
                auto ie = parseExpr();
                if (tp != tend)
                    throw fail();
                toks = saveToks;
                tp = saveTp;
                tend = saveEnd;
                if (buf.length)
                {
                    parts ~= StrPart((() @trusted => cast(string) buf.dup)(), null);
                    buf.length = 0;
                }
                parts ~= StrPart(null, ie);
                i = cast(size_t) end;
            }
            else if (c == '}')
            {
                if (i + 1 < n && body_[i + 1] == '}')
                {
                    buf ~= '}';
                    i += 2;
                }
                else
                    throw fail();
            }
            else
            {
                buf ~= c;
                ++i;
            }
        }
        if (parts.length == 0)
        {
            e.kind = ExprKind.strLit;
            e.name = (() @trusted => cast(string) buf)();
            return e;
        }
        if (buf.length)
            parts ~= StrPart((() @trusted => cast(string) buf)(), null);
        e.kind = ExprKind.interp;
        e.parts = parts;
        return e;
    }
}
