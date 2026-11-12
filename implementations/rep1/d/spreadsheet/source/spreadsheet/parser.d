/**
 * Parsing of cell contents and formulas.
 *
 * $(LREF parseContent) classifies the text given to `set` as a number, a
 * string literal or a formula; $(LREF parseFormula) is a recursive-descent
 * parser for the formula grammar producing an $(REF Expr, spreadsheet,ast) tree.
 */
module spreadsheet.parser;

import core.stdc.stdlib : strtod;
import spreadsheet.ast;
import spreadsheet.cellref;
import spreadsheet.value;

/// Thrown for content that does not follow the grammar.
class ParseException : Exception
{
    this(string msg, string file = __FILE__, size_t line = __LINE__) pure nothrow @safe
    {
        super(msg, file, line);
    }
}

/// What a cell holds.
enum ContentKind : ubyte
{
    empty,   /// nothing
    number,  /// number literal; `literal` is set
    text,    /// string literal; `literal` is set
    formula, /// formula; `formula` is set
}

/// Parsed cell content.
struct Content
{
    ContentKind kind;
    /// The value of a number or string literal.
    Value literal;
    /// The syntax tree of a formula.
    Expr formula;
}

/// Converts a decimal literal (`-?[0-9]+(\.[0-9]+)?`) to the nearest double.
double parseNumber(const(char)[] text) nothrow @trusted
{
    char[64] small;
    char[] buf = text.length < small.length ? small[] : new char[text.length + 1];
    buf[0 .. text.length] = text;
    buf[text.length] = 0;
    const d = strtod(buf.ptr, null);
    return d == 0 ? 0 : d; // normalise -0
}

private bool isNumberLiteral(const(char)[] s) pure nothrow @nogc @safe
{
    size_t i = s.length && s[0] == '-' ? 1 : 0;
    const intStart = i;
    while (i < s.length && s[i] >= '0' && s[i] <= '9')
        i++;
    if (i == intStart)
        return false;
    if (i < s.length && s[i] == '.')
    {
        const fracStart = ++i;
        while (i < s.length && s[i] >= '0' && s[i] <= '9')
            i++;
        if (i == fracStart)
            return false;
    }
    return i == s.length;
}

/**
 * Parses the content argument of a `set` command.
 *
 * Throws: $(LREF ParseException) if it is none of formula, string literal or number.
 */
Content parseContent(string text) @safe
{
    Content c;
    if (text.length && text[0] == '=')
    {
        c.kind = ContentKind.formula;
        c.formula = parseFormula(text[1 .. $]);
    }
    else if (text.length && text[0] == '"')
    {
        if (text.length < 2 || text[$ - 1] != '"')
            throw new ParseException("unterminated string literal");
        c.kind = ContentKind.text;
        c.literal = Value.makeText(text[1 .. $ - 1]);
    }
    else if (isNumberLiteral(text))
    {
        c.kind = ContentKind.number;
        c.literal = Value.makeNumber(parseNumber(text));
    }
    else
        throw new ParseException("invalid cell content: " ~ text);
    return c;
}

/**
 * Parses a formula (the text after the leading `=`).
 *
 * A formula containing an invalid cell reference anywhere is not a syntax
 * error: the result is a constant `#REF!` expression, which depends on
 * no cells.
 *
 * Throws: $(LREF ParseException) on a syntax error.
 */
Expr parseFormula(string text) @safe
{
    auto p = Parser(text);
    auto e = p.parseExpr();
    p.skipSpaces();
    if (p.pos != text.length)
        throw new ParseException("unexpected trailing input in formula");
    if (p.badReference)
        return Expr.literal(Value.makeError(ErrorCode.ref_));
    return e;
}

private struct Parser
{
    string src;
    size_t pos;
    bool badReference;

    this(string s) nothrow @nogc @safe
    {
        src = s;
    }

    void skipSpaces() nothrow @nogc @safe
    {
        while (pos < src.length && src[pos] == ' ')
            pos++;
    }

    /// Next non-space character, or 0 at the end.
    char peek() nothrow @nogc @safe
    {
        skipSpaces();
        return pos < src.length ? src[pos] : '\0';
    }

    bool accept(char c) nothrow @nogc @safe
    {
        if (peek() == c)
        {
            pos++;
            return true;
        }
        return false;
    }

    void expect(char c) @safe
    {
        if (!accept(c))
            throw new ParseException("expected '" ~ c ~ "' in formula");
    }

    static Expr binary(BinaryOp op, Expr a, Expr b) nothrow @safe
    {
        auto e = new Expr(ExprKind.binary);
        e.op = op;
        e.args = [a, b];
        return e;
    }

    Expr parseExpr() @safe
    {
        auto left = parseConcat();
        for (;;)
        {
            BinaryOp op;
            const c = peek();
            if (c == '=')
            {
                op = BinaryOp.eq;
                pos++;
            }
            else if (c == '<')
            {
                pos++;
                if (pos < src.length && src[pos] == '>')
                {
                    pos++;
                    op = BinaryOp.ne;
                }
                else if (pos < src.length && src[pos] == '=')
                {
                    pos++;
                    op = BinaryOp.le;
                }
                else
                    op = BinaryOp.lt;
            }
            else if (c == '>')
            {
                pos++;
                if (pos < src.length && src[pos] == '=')
                {
                    pos++;
                    op = BinaryOp.ge;
                }
                else
                    op = BinaryOp.gt;
            }
            else
                return left;
            left = binary(op, left, parseConcat());
        }
    }

    Expr parseConcat() @safe
    {
        auto left = parseAdd();
        while (accept('&'))
            left = binary(BinaryOp.concat, left, parseAdd());
        return left;
    }

    Expr parseAdd() @safe
    {
        auto left = parseMul();
        for (;;)
        {
            const c = peek();
            if (c != '+' && c != '-')
                return left;
            pos++;
            left = binary(c == '+' ? BinaryOp.add : BinaryOp.sub, left, parseMul());
        }
    }

    Expr parseMul() @safe
    {
        auto left = parseUnary();
        for (;;)
        {
            const c = peek();
            if (c != '*' && c != '/')
                return left;
            pos++;
            left = binary(c == '*' ? BinaryOp.mul : BinaryOp.div, left, parseUnary());
        }
    }

    Expr parseUnary() @safe
    {
        if (accept('-'))
        {
            auto e = new Expr(ExprKind.negate);
            e.args = [parseUnary()];
            return e;
        }
        return parsePrimary();
    }

    Expr parsePrimary() @safe
    {
        const c = peek();
        if (c == '(')
        {
            pos++;
            auto e = parseExpr();
            expect(')');
            return e;
        }
        if (c == '"')
        {
            const start = ++pos;
            while (pos < src.length && src[pos] != '"')
                pos++;
            if (pos == src.length)
                throw new ParseException("unterminated string in formula");
            return Expr.literal(Value.makeText(src[start .. pos++]));
        }
        if (c >= '0' && c <= '9')
        {
            const start = pos;
            while (pos < src.length && src[pos] >= '0' && src[pos] <= '9')
                pos++;
            if (pos + 1 < src.length && src[pos] == '.' && src[pos + 1] >= '0' && src[pos + 1] <= '9')
            {
                pos++;
                while (pos < src.length && src[pos] >= '0' && src[pos] <= '9')
                    pos++;
            }
            return Expr.literal(Value.makeNumber(parseNumber(src[start .. pos])));
        }
        if (c >= 'A' && c <= 'Z')
        {
            const word = lexWord();
            if (peek() == '(')
                return parseCall(word);
            return makeReference(word);
        }
        throw new ParseException("unexpected character in formula");
    }

    /// Reads `[A-Z]+[0-9]*` (a function name or a reference token).
    string lexWord() nothrow @nogc @safe
    {
        const start = pos;
        while (pos < src.length && src[pos] >= 'A' && src[pos] <= 'Z')
            pos++;
        while (pos < src.length && src[pos] >= '0' && src[pos] <= '9')
            pos++;
        return src[start .. pos];
    }

    Expr makeReference(string token) nothrow @safe
    {
        auto e = new Expr(ExprKind.reference);
        if (!tryParseCellRef(token, e.cell))
            badReference = true;
        return e;
    }

    Expr parseCall(string name) @safe
    {
        expect('(');
        if (name == "IF")
        {
            auto e = new Expr(ExprKind.conditional);
            e.args ~= parseExpr();
            expect(',');
            e.args ~= parseExpr();
            expect(',');
            e.args ~= parseExpr();
            expect(')');
            return e;
        }
        auto e = new Expr(ExprKind.aggregate);
        switch (name)
        {
        case "SUM":   e.fn = Aggregate.sum; break;
        case "MIN":   e.fn = Aggregate.min; break;
        case "MAX":   e.fn = Aggregate.max; break;
        case "AVG":   e.fn = Aggregate.avg; break;
        case "COUNT": e.fn = Aggregate.count; break;
        default: throw new ParseException("unknown function " ~ name);
        }
        do
            e.args ~= parseArgument();
        while (accept(','));
        expect(')');
        return e;
    }

    /// An aggregate argument: an expression or a `REF:REF` range.
    Expr parseArgument() @safe
    {
        const save = pos;
        if (peek() >= 'A' && peek() <= 'Z')
        {
            const first = lexWord();
            if (pos < src.length && src[pos] == ':')
            {
                pos++;
                const second = lexWord();
                auto e = new Expr(ExprKind.range);
                const ok1 = tryParseCellRef(first, e.cell);
                const ok2 = tryParseCellRef(second, e.cellEnd);
                if (!ok1 || !ok2)
                    badReference = true;
                return e;
            }
            pos = save;
        }
        return parseExpr();
    }
}

@safe unittest
{
    assert(parseContent("5").kind == ContentKind.number);
    assert(parseContent("-0").literal.number == 0);
    assert(parseContent("4.50").literal.number == 4.5);
    assert(parseContent("007").literal.number == 7);
    assert(parseContent(`"a b"`).literal.text == "a b");
    assert(parseContent(`""`).kind == ContentKind.text);
    assert(parseContent("=1+2").kind == ContentKind.formula);
}

@safe unittest
{
    import std.exception : assertThrown;
    assertThrown!ParseException(parseContent("abc"));
    assertThrown!ParseException(parseContent(`"abc`));
    assertThrown!ParseException(parseContent("=1+"));
    assertThrown!ParseException(parseContent("=(1"));
    assertThrown!ParseException(parseContent("=FOO(1)"));
    assertThrown!ParseException(parseContent("1."));
}

@safe unittest
{
    // invalid references anywhere make the whole formula a constant #REF!
    foreach (f; ["=AAA1", "=A0+1", "=IF(1,2,A10000)", "=SUM(A1:AAA1)", "=A01"])
    {
        auto e = parseContent(f).formula;
        assert(e.kind == ExprKind.error && e.value.error == ErrorCode.ref_, f);
    }
    uint[] deps;
    collectDependencies(parseContent("=SUM(A1:B2)+C3").formula, deps);
    assert(deps.length == 5);
}
