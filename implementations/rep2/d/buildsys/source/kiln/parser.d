/**
 * The KBL parser: turns logical lines into statement trees.
 *
 * Syntax errors surface as `KilnError` `E_PARSE <file>:<line>`, using the
 * precedence the spec requires: lexical errors for the whole file first, then
 * the first grammar error in file order, then unterminated blocks.
 */
module kiln.parser;

import kiln.ast;
import kiln.errors : failParse;
import kiln.lexer;
import kiln.value : Value;

/// Parses the build file `src` (whose workspace path is `file`).
Stmt[] parseBuildFile(string src, string file) @safe pure
{
    auto lines = lexFile(src, file);
    return FileParser(file).parse(lines);
}

private enum FrameKind : ubyte
{
    root,
    whenBranch,
    otherwiseBranch,
    each,
    rule,
    step,
}

private final class Frame
{
    FrameKind kind;
    int line;
    Stmt owner;
    Stmt[] stmts;

    this(FrameKind kind, int line, Stmt owner) @safe pure nothrow @nogc
    {
        this.kind = kind;
        this.line = line;
        this.owner = owner;
    }
}

private struct FileParser
{
    string file;
    Frame[] stack;

    Stmt[] parse(LogicalLine[] lines) @safe pure
    {
        stack = [new Frame(FrameKind.root, 0, null)];
        foreach (ref ll; lines)
        {
            try
                parseLine(ll);
            catch (SyntaxFailure)
                failParse(file, ll.number);
        }
        if (stack.length > 1)
            failParse(file, stack[$ - 1].line); // innermost unterminated block
        return stack[0].stmts;
    }

    private Frame top() @safe pure nothrow @nogc
    {
        return stack[$ - 1];
    }

    private void parseLine(ref LogicalLine ll) @safe pure
    {
        auto toks = ll.tokens;
        if (toks[0].isSym("}"))
            return parseTerminator(ll);
        if (toks[$ - 1].isSym("{"))
            return parseHeader(ll);
        auto st = top().kind == FrameKind.step ? parseStepField(toks, ll.number) : parseSimple(toks,
                ll.number);
        top().stmts ~= st;
    }

    // ---- block terminators ------------------------------------------------

    private void parseTerminator(ref LogicalLine ll) @safe pure
    {
        auto toks = ll.tokens;
        if (stack.length == 1)
            throw new SyntaxFailure;
        if (toks.length == 1)
        {
            closeFrame();
            return;
        }
        auto f = top();
        if (toks[1].isWord("elsewhen"))
        {
            if (f.kind != FrameKind.whenBranch || !toks[$ - 1].isSym("{") || toks.length < 4)
                throw new SyntaxFailure;
            auto ep = ExprParser(toks[2 .. $ - 1]);
            auto cond = ep.parseWhole();
            auto owner = f.owner;
            closeFrame();
            owner.conds ~= cond;
            stack ~= new Frame(FrameKind.whenBranch, ll.number, owner);
            return;
        }
        if (toks[1].isWord("otherwise"))
        {
            if (f.kind != FrameKind.whenBranch || toks.length != 3 || !toks[2].isSym("{"))
                throw new SyntaxFailure;
            auto owner = f.owner;
            closeFrame();
            owner.hasOtherwise = true;
            stack ~= new Frame(FrameKind.otherwiseBranch, ll.number, owner);
            return;
        }
        throw new SyntaxFailure;
    }

    private void closeFrame() @safe pure
    {
        auto f = top();
        stack = stack[0 .. $ - 1];
        final switch (f.kind)
        {
        case FrameKind.root:
            assert(0);
        case FrameKind.whenBranch:
            f.owner.branches ~= f.stmts;
            break;
        case FrameKind.otherwiseBranch:
            f.owner.otherwise = f.stmts;
            break;
        case FrameKind.each:
        case FrameKind.rule:
            f.owner.children = f.stmts;
            break;
        case FrameKind.step:
            f.owner.fields = f.stmts;
            break;
        }
    }

    // ---- block headers ----------------------------------------------------

    private void parseHeader(ref LogicalLine ll) @safe pure
    {
        auto toks = ll.tokens;
        if (top().kind == FrameKind.step)
            throw new SyntaxFailure;
        auto st = new Stmt;
        st.line = ll.number;
        if (toks[0].isWord("step"))
        {
            if (toks.length != 2)
                throw new SyntaxFailure;
            st.kind = StmtKind.step;
            top().stmts ~= st;
            stack ~= new Frame(FrameKind.step, ll.number, st);
        }
        else if (toks[0].isWord("when"))
        {
            if (toks.length < 3)
                throw new SyntaxFailure;
            st.kind = StmtKind.when;
            auto ep = ExprParser(toks[1 .. $ - 1]);
            st.conds ~= ep.parseWhole();
            top().stmts ~= st;
            stack ~= new Frame(FrameKind.whenBranch, ll.number, st);
        }
        else if (toks[0].isWord("each"))
        {
            st.kind = StmtKind.each;
            size_t p = 1;
            st.name = identAt(toks, p++);
            if (toks[p].isSym(","))
            {
                p++;
                st.indexName = st.name;
                st.name = identAt(toks, p++);
                if (st.indexName == st.name)
                    throw new SyntaxFailure;
            }
            if (p >= toks.length || !toks[p].isWord("in"))
                throw new SyntaxFailure;
            p++;
            if (p >= toks.length - 1)
                throw new SyntaxFailure;
            auto ep = ExprParser(toks[p .. $ - 1]);
            st.expr = ep.parseWhole();
            top().stmts ~= st;
            stack ~= new Frame(FrameKind.each, ll.number, st);
        }
        else if (toks[0].isWord("rule"))
        {
            st.kind = StmtKind.rule;
            size_t p = 1;
            st.name = identAt(toks, p++);
            if (toks.length < 5 || !toks[p].isSym("(") || !toks[$ - 2].isSym(")"))
                throw new SyntaxFailure;
            auto ep = ExprParser(toks[p + 1 .. $ - 2]);
            st.params = ep.parseParams();
            top().stmts ~= st;
            stack ~= new Frame(FrameKind.rule, ll.number, st);
        }
        else
        {
            throw new SyntaxFailure;
        }
    }

    // ---- simple statements ------------------------------------------------

    private Stmt parseSimple(Token[] toks, int line) @safe pure
    {
        auto st = new Stmt;
        st.line = line;
        if (toks[0].kind != TokenKind.identifier)
            throw new SyntaxFailure;
        switch (toks[0].text)
        {
        case "let":
        case "set":
            st.kind = toks[0].text == "let" ? StmtKind.let : StmtKind.set;
            return parseBinding(st, toks);
        case "include":
            st.kind = StmtKind.include;
            break;
        case "abort":
            st.kind = StmtKind.abort;
            break;
        case "default":
            st.kind = StmtKind.defaultTargets;
            break;
        case "phony":
            st.kind = StmtKind.phony;
            return parseBinding(st, toks);
        case "use":
            st.kind = StmtKind.use;
            if (toks.length < 4 || toks[1].kind != TokenKind.identifier
                    || !toks[2].isSym("(") || !toks[$ - 1].isSym(")"))
                throw new SyntaxFailure;
            st.name = toks[1].text;
            auto uep = ExprParser(toks[3 .. $ - 1]);
            st.useArgs = uep.parseUseArgs();
            return st;
        default:
            throw new SyntaxFailure;
        }
        // include / abort / default: keyword followed by one expression
        auto ep = ExprParser(toks[1 .. $]);
        st.expr = ep.parseWhole();
        return st;
    }

    /// `KEYWORD IDENT = expr`
    private Stmt parseBinding(Stmt st, Token[] toks) @safe pure
    {
        immutable p = 2;
        st.name = identAt(toks, 1);
        if (toks.length <= p || !toks[p].isSym("="))
            throw new SyntaxFailure;
        auto ep = ExprParser(toks[p + 1 .. $]);
        st.expr = ep.parseWhole();
        return st;
    }

    private Stmt parseStepField(Token[] toks, int line) @safe pure
    {
        auto st = new Stmt;
        st.line = line;
        if (toks[0].kind != TokenKind.identifier)
            throw new SyntaxFailure;
        switch (toks[0].text)
        {
        case "out":
            st.kind = StmtKind.fieldOut;
            break;
        case "in":
            st.kind = StmtKind.fieldIn;
            break;
        case "after":
            st.kind = StmtKind.fieldAfter;
            break;
        case "cost":
            st.kind = StmtKind.fieldCost;
            break;
        case "depfile":
            st.kind = StmtKind.fieldDepfile;
            break;
        case "cmd":
            st.kind = StmtKind.fieldCmd;
            if (toks.length < 4 || toks[1].kind != TokenKind.identifier
                    || !toks[2].isSym("(") || !toks[$ - 1].isSym(")"))
                throw new SyntaxFailure;
            st.name = toks[1].text;
            auto cep = ExprParser(toks[3 .. $ - 1]);
            st.cmdArgs = cep.parseExprList();
            return st;
        default:
            throw new SyntaxFailure;
        }
        auto ep = ExprParser(toks[1 .. $]);
        st.expr = ep.parseWhole();
        return st;
    }
}

/// An identifier token at `toks[p]` that is not a reserved word.
private string identAt(Token[] toks, size_t p) @safe pure
{
    if (p >= toks.length || toks[p].kind != TokenKind.identifier || isReserved(toks[p].text))
        throw new SyntaxFailure;
    return toks[p].text;
}

/// Recursive-descent/precedence-climbing parser over a token slice.
struct ExprParser
{
    Token[] toks;
    size_t pos;

    this(Token[] toks) @safe pure nothrow @nogc
    {
        this.toks = toks;
    }

    private bool atEnd() const @safe pure nothrow @nogc
    {
        return pos >= toks.length;
    }

    private bool peekSym(string s) const @safe pure nothrow @nogc
    {
        return pos < toks.length && toks[pos].isSym(s);
    }

    private void expectSym(string s) @safe pure
    {
        if (!peekSym(s))
            throw new SyntaxFailure;
        pos++;
    }

    /// Parses one expression that must consume every token.
    Expr parseWhole() @safe pure
    {
        auto e = parseExpr();
        if (!atEnd())
            throw new SyntaxFailure;
        return e;
    }

    /// `expr { "," expr } [ "," ]` — possibly empty — consuming everything.
    Expr[] parseExprList() @safe pure
    {
        Expr[] items;
        while (!atEnd())
        {
            items ~= parseExpr();
            if (atEnd())
                break;
            expectSym(",");
        }
        return items;
    }

    /// A `use` argument list consuming everything.
    UseArg[] parseUseArgs() @safe pure
    {
        UseArg[] args;
        bool sawKeyword = false;
        while (!atEnd())
        {
            UseArg a;
            if (toks[pos].kind == TokenKind.identifier && !isReserved(toks[pos].text)
                    && pos + 1 < toks.length && toks[pos + 1].isSym("="))
            {
                a.keyword = toks[pos].text;
                pos += 2;
                sawKeyword = true;
            }
            else if (sawKeyword)
            {
                throw new SyntaxFailure; // positional after keyword
            }
            a.value = parseExpr();
            args ~= a;
            if (atEnd())
                break;
            expectSym(",");
        }
        return args;
    }

    /// A rule parameter list consuming everything.
    Param[] parseParams() @safe pure
    {
        Param[] params;
        bool sawDefault = false;
        while (!atEnd())
        {
            Param p;
            p.name = identAt(toks, pos++);
            foreach (ref q; params)
                if (q.name == p.name)
                    throw new SyntaxFailure;
            if (peekSym("="))
            {
                pos++;
                p.defaultValue = parseExpr();
                sawDefault = true;
            }
            else if (sawDefault)
            {
                throw new SyntaxFailure;
            }
            params ~= p;
            if (atEnd())
                break;
            expectSym(",");
        }
        return params;
    }

    // ---- expressions, lowest precedence first --------------------------------

    Expr parseExpr() @safe pure
    {
        auto lhs = parseOr();
        while (peekSym("|>"))
        {
            pos++;
            if (atEnd() || toks[pos].kind != TokenKind.identifier)
                throw new SyntaxFailure;
            auto call = new Expr;
            call.kind = ExprKind.call;
            call.name = toks[pos++].text;
            call.args = [lhs];
            if (peekSym("("))
            {
                pos++;
                call.args ~= parseArgsUntilClose();
            }
            lhs = call;
        }
        return lhs;
    }

    private Expr[] parseArgsUntilClose() @safe pure
    {
        Expr[] items;
        while (true)
        {
            if (peekSym(")"))
            {
                pos++;
                return items;
            }
            items ~= parseExpr();
            if (peekSym(","))
            {
                pos++;
                continue;
            }
            expectSym(")");
            return items;
        }
    }

    private Expr binary(BinOp op, Expr l, Expr r) @safe pure nothrow
    {
        auto e = new Expr;
        e.kind = ExprKind.binary;
        e.binop = op;
        e.lhs = l;
        e.rhs = r;
        return e;
    }

    private Expr parseOr() @safe pure
    {
        auto l = parseAnd();
        while (peekSym("||"))
        {
            pos++;
            l = binary(BinOp.or, l, parseAnd());
        }
        return l;
    }

    private Expr parseAnd() @safe pure
    {
        auto l = parseCmp();
        while (peekSym("&&"))
        {
            pos++;
            l = binary(BinOp.and, l, parseCmp());
        }
        return l;
    }

    private Expr parseCmp() @safe pure
    {
        auto l = parseListCat();
        while (true)
        {
            BinOp op;
            if (peekSym("=="))
                op = BinOp.eq;
            else if (peekSym("!="))
                op = BinOp.ne;
            else if (peekSym("<"))
                op = BinOp.lt;
            else if (peekSym("<="))
                op = BinOp.le;
            else if (peekSym(">"))
                op = BinOp.gt;
            else if (peekSym(">="))
                op = BinOp.ge;
            else
                return l;
            pos++;
            l = binary(op, l, parseListCat());
        }
    }

    private Expr parseListCat() @safe pure
    {
        auto l = parseStrCat();
        while (peekSym("++"))
        {
            pos++;
            l = binary(BinOp.listCat, l, parseStrCat());
        }
        return l;
    }

    private Expr parseStrCat() @safe pure
    {
        auto l = parseAdd();
        while (peekSym("~"))
        {
            pos++;
            l = binary(BinOp.strCat, l, parseAdd());
        }
        return l;
    }

    private Expr parseAdd() @safe pure
    {
        auto l = parseMul();
        while (true)
        {
            BinOp op;
            if (peekSym("+"))
                op = BinOp.add;
            else if (peekSym("-"))
                op = BinOp.sub;
            else
                return l;
            pos++;
            l = binary(op, l, parseMul());
        }
    }

    private Expr parseMul() @safe pure
    {
        auto l = parseUnary();
        while (true)
        {
            BinOp op;
            if (peekSym("*"))
                op = BinOp.mul;
            else if (peekSym("/"))
                op = BinOp.div;
            else if (peekSym("%"))
                op = BinOp.mod;
            else
                return l;
            pos++;
            l = binary(op, l, parseUnary());
        }
    }

    private Expr parseUnary() @safe pure
    {
        if (peekSym("!") || peekSym("-"))
        {
            auto e = new Expr;
            e.kind = ExprKind.unary;
            e.unop = toks[pos].text == "!" ? UnOp.not : UnOp.neg;
            pos++;
            e.lhs = parseUnary();
            return e;
        }
        return parsePostfix();
    }

    private Expr parsePostfix() @safe pure
    {
        auto e = parsePrimary();
        if (peekSym("("))
            throw new SyntaxFailure; // a call applies only to an identifier primary
        while (peekSym("["))
        {
            pos++;
            auto ix = new Expr;
            ix.kind = ExprKind.index;
            ix.lhs = e;
            ix.rhs = parseExpr();
            expectSym("]");
            e = ix;
            if (peekSym("("))
                throw new SyntaxFailure;
        }
        return e;
    }

    private Expr parsePrimary() @safe pure
    {
        if (atEnd())
            throw new SyntaxFailure;
        auto t = toks[pos];
        auto e = new Expr;
        final switch (t.kind)
        {
        case TokenKind.integer:
            pos++;
            e.kind = ExprKind.literal;
            e.lit = Value.ofInt(t.intValue);
            return e;
        case TokenKind.str:
            pos++;
            return t.doubleQuoted ? parseDoubleQuoted(t.text) : singleQuoted(t.text);
        case TokenKind.identifier:
            pos++;
            if (peekSym("("))
            {
                // A call; reserved words are allowed in this position only.
                pos++;
                e.kind = ExprKind.call;
                e.name = t.text;
                e.args = parseArgsUntilClose();
                return e;
            }
            if (t.text == "true" || t.text == "false")
            {
                e.kind = ExprKind.literal;
                e.lit = Value.ofBool(t.text == "true");
                return e;
            }
            if (isReserved(t.text))
                throw new SyntaxFailure;
            e.kind = ExprKind.variable;
            e.name = t.text;
            return e;
        case TokenKind.punct:
            if (t.text == "(")
            {
                pos++;
                auto inner = parseExpr();
                expectSym(")");
                return inner;
            }
            if (t.text == "[")
            {
                pos++;
                e.kind = ExprKind.list;
                while (true)
                {
                    if (peekSym("]"))
                    {
                        pos++;
                        break;
                    }
                    e.args ~= parseExpr();
                    if (peekSym(","))
                    {
                        pos++;
                        continue;
                    }
                    expectSym("]");
                    break;
                }
                return e;
            }
            throw new SyntaxFailure;
        case TokenKind.op:
            throw new SyntaxFailure;
        }
    }
}

private Expr literalString(string s) @safe pure nothrow
{
    auto e = new Expr;
    e.kind = ExprKind.literal;
    e.lit = Value.ofStr(s);
    return e;
}

private Expr singleQuoted(string raw) @safe pure
{
    char[] buf;
    size_t i = 0;
    while (i < raw.length)
    {
        buf ~= raw[i];
        i += (raw[i] == '\'' && i + 1 < raw.length && raw[i + 1] == '\'') ? 2 : 1;
    }
    return literalString((() @trusted => cast(string) buf)());
}

/// Decodes the body of a double-quoted literal into text and interpolation parts.
private Expr parseDoubleQuoted(string raw) @safe pure
{
    StrPart[] parts;
    char[] lit;
    size_t i = 0;
    void flush() @safe pure nothrow
    {
        if (lit.length)
        {
            parts ~= StrPart((() @trusted => cast(string) lit.idup)(), null);
            lit.length = 0;
        }
    }

    while (i < raw.length)
    {
        immutable c = raw[i];
        if (c == '\\')
        {
            if (i + 1 >= raw.length)
                throw new SyntaxFailure;
            switch (raw[i + 1])
            {
            case '\\':
                lit ~= '\\';
                break;
            case '"':
                lit ~= '"';
                break;
            case 'n':
                lit ~= '\n';
                break;
            case 't':
                lit ~= '\t';
                break;
            case 'r':
                lit ~= '\r';
                break;
            case '0':
                lit ~= '\0';
                break;
            default:
                throw new SyntaxFailure;
            }
            i += 2;
        }
        else if (c == '{')
        {
            if (i + 1 < raw.length && raw[i + 1] == '{')
            {
                lit ~= '{';
                i += 2;
                continue;
            }
            immutable end = skipInterpolation(raw, i + 1);
            if (end < 0)
                throw new SyntaxFailure;
            auto interp = raw[i + 1 .. cast(size_t) end - 1];
            auto toks = tokenize(interp);
            if (toks.length == 0)
                throw new SyntaxFailure;
            auto ep = ExprParser(toks);
            auto inner = ep.parseWhole();
            flush();
            parts ~= StrPart("", inner);
            i = cast(size_t) end;
        }
        else if (c == '}')
        {
            if (i + 1 < raw.length && raw[i + 1] == '}')
            {
                lit ~= '}';
                i += 2;
                continue;
            }
            throw new SyntaxFailure;
        }
        else
        {
            lit ~= c;
            i++;
        }
    }
    flush();
    bool plain = true;
    foreach (ref p; parts)
        if (p.expr !is null)
            plain = false;
    if (plain)
    {
        string s;
        foreach (ref p; parts)
            s ~= p.text;
        return literalString(s);
    }
    auto e = new Expr;
    e.kind = ExprKind.interpolated;
    e.parts = parts;
    return e;
}

@safe pure unittest
{
    import kiln.errors : KilnError;
    import std.exception : collectException;

    auto stmts = parseBuildFile("let a = 1 + 2 * 3\nwhen a > 3 {\n  default \"x\"\n} otherwise {\n  abort \"no\"\n}\n", "m");
    assert(stmts.length == 2 && stmts[0].kind == StmtKind.let && stmts[1].kind == StmtKind.when);
    assert(stmts[1].branches.length == 1 && stmts[1].hasOtherwise && stmts[1].otherwise.length == 1);

    stmts = parseBuildFile("step {\n  out \"out/a\"\n  cmd write(\"hi\")\n}\n", "m");
    assert(stmts.length == 1 && stmts[0].fields.length == 2);

    // Lexical errors beat grammar errors; unterminated blocks come last.
    auto e = collectException!KilnError(parseBuildFile("let = 1\nlet x = \"abc\n", "m"));
    assert(e && e.detail == "m:2");
    e = collectException!KilnError(parseBuildFile("when true {\n  let a = 1\n", "m"));
    assert(e && e.detail == "m:1");
    e = collectException!KilnError(parseBuildFile("when true {\n} otherwise {\n  let a = 1\n", "m"));
    assert(e && e.detail == "m:2");
    e = collectException!KilnError(parseBuildFile("}\n", "m"));
    assert(e && e.detail == "m:1");
    e = collectException!KilnError(parseBuildFile("let s = \"{}\"\n", "m"));
    assert(e && e.detail == "m:1");
    e = collectException!KilnError(parseBuildFile("let s = \"a}b\"\n", "m"));
    assert(e);
    e = collectException!KilnError(parseBuildFile("let s = f(1)(2)\n", "m"));
    assert(e);
    e = collectException!KilnError(parseBuildFile("each a, a in [] {\n}\n", "m"));
    assert(e);
    e = collectException!KilnError(parseBuildFile("rule r(a = 1, b) {\n}\n", "m"));
    assert(e);
    // Reserved words are accepted only as call names.
    assert(collectException!KilnError(parseBuildFile("let x = cost(1)\n", "m")) is null);
    assert(collectException!KilnError(parseBuildFile("let cost = 1\n", "m")) !is null);
}
